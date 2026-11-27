defmodule QPBX.Core.Trunks do
  @moduledoc """
  Carrier trunks. A platform scope manages the shared carrier trunks (no tenant); a tenant
  scope manages the tenant's own. An address of an IP-authenticated trunk identifies the
  trunk for incoming calls, so it may belong to one IP trunk only, across all tenants.
  """
  import Ecto.Query
  alias QPBX.Core.{Changes, Scope, Trunk, TrunkAddress}
  alias QPBX.Repo

  def list(%Scope{kind: :platform}),
    do:
      Repo.all(from t in Trunk, where: is_nil(t.tenant_id), order_by: t.name, preload: :addresses)

  def list(%Scope{kind: :tenant, tenant_id: tid} = scope),
    do:
      Scope.run(scope, fn ->
        Repo.all(
          from t in Trunk, where: t.tenant_id == ^tid, order_by: t.name, preload: :addresses
        )
      end)

  @doc "Trunks a tenant's routes may use: its own and the platform's (id and name only)."
  def choices(%Scope{kind: :tenant, tenant_id: tid}) do
    Repo.all(
      from t in Trunk,
        where: (is_nil(t.tenant_id) or t.tenant_id == ^tid) and t.enabled,
        order_by: [asc: not is_nil(t.tenant_id), asc: t.name],
        select: %{id: t.id, name: t.name, platform?: is_nil(t.tenant_id)}
    )
  end

  @doc """
  Every enabled registration trunk, all tenants, with its decrypted password and addresses:
  the edge registers them at the carriers. Not for tenant-facing code.
  """
  def registration_trunks do
    Repo.all(
      from t in Trunk,
        where: t.enabled and t.auth_mode == "registration",
        order_by: t.edge_id,
        preload: :addresses
    )
  end

  def get!(%Scope{} = scope, id),
    do: Scope.run(scope, fn -> Repo.one!(where(own(scope), id: ^id) |> preload(:addresses)) end)

  def change(%Trunk{} = trunk \\ %Trunk{addresses: []}, attrs \\ %{}),
    do: Trunk.changeset(trunk, attrs)

  def create(%Scope{} = scope, attrs, actor) do
    tid = tenant_id(scope)
    cs = Trunk.changeset(%Trunk{tenant_id: tid, addresses: []}, attrs)

    with :ok <- unique_ip_addresses(cs),
         do:
           Scope.run(scope, fn -> Changes.insert(cs, actor, "trunk.create") end)
           |> Changes.announce(tid, "trunks")
  end

  def update(%Scope{} = scope, %Trunk{} = trunk, attrs, actor) do
    tid = tenant_id(scope)
    ^tid = trunk.tenant_id
    cs = Trunk.changeset(Repo.preload(trunk, :addresses), attrs)

    with :ok <- unique_ip_addresses(cs),
         do:
           Scope.run(scope, fn -> Changes.update(cs, actor, "trunk.update") end)
           |> Changes.announce(tid, "trunks")
  end

  @doc "Refused while a route, DID or emergency route still uses the trunk."
  def delete(%Scope{} = scope, %Trunk{} = trunk, actor) do
    tid = tenant_id(scope)
    ^tid = trunk.tenant_id

    Scope.run(scope, fn ->
      trunk
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.foreign_key_constraint(:id,
        name: :route_trunks_trunk_id_fkey,
        message: "used by an outbound route"
      )
      |> Ecto.Changeset.foreign_key_constraint(:id,
        name: :emergency_routes_trunk_id_fkey,
        message: "used by an emergency route"
      )
      |> Changes.delete(actor, "trunk.delete", %{name: trunk.name})
    end)
    |> Changes.announce(tid, "trunks")
  end

  # Checked across tenants (row-level security would hide the others), outside the write.
  # shortcut: two tenants saving the same IP at the same instant could both pass; add a unique
  # index on a denormalized auth_mode column if that ever matters.
  defp unique_ip_addresses(cs) do
    trunk_id = cs.data.id

    hosts =
      for %{action: a} = a_cs <- Ecto.Changeset.get_change(cs, :addresses, []) || [],
          a in [:insert, :update],
          do: Ecto.Changeset.get_field(a_cs, :host)

    hosts =
      if hosts == [] and cs.data.id,
        do: Repo.all(from a in TrunkAddress, where: a.trunk_id == ^trunk_id, select: a.host),
        else: hosts

    query =
      from a in TrunkAddress,
        join: t in Trunk,
        on: t.id == a.trunk_id,
        where: t.auth_mode == "ip" and a.host in ^hosts

    query = if trunk_id, do: where(query, [_, t], t.id != ^trunk_id), else: query
    taken = Ecto.Changeset.get_field(cs, :auth_mode) == "ip" and Repo.exists?(query)

    if taken,
      do:
        {:error,
         Ecto.Changeset.add_error(
           cs,
           :addresses,
           "an address is already used by another IP trunk"
         )},
      else: :ok
  end

  defp own(%Scope{kind: :platform}), do: from(t in Trunk, where: is_nil(t.tenant_id))

  defp own(%Scope{kind: :tenant, tenant_id: tid}),
    do: from(t in Trunk, where: t.tenant_id == ^tid)

  defp tenant_id(%Scope{kind: :platform}), do: nil
  defp tenant_id(%Scope{kind: :tenant, tenant_id: tid}), do: tid
end
