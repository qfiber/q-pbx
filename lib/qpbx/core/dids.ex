defmodule QPBX.Core.Dids do
  @moduledoc """
  Phone numbers. The platform adds them on a carrier trunk and assigns them to tenants; a
  tenant points its numbers at destinations. A backup number belongs to the same tenant as its
  main number and routes like it.
  """
  import Ecto.Query
  alias QPBX.Core.{Changes, Did, Extension, Scope}
  alias QPBX.Repo

  def list(%Scope{kind: :platform}), do: Repo.all(from d in Did, order_by: d.number)

  def list(%Scope{kind: :tenant, tenant_id: tid} = scope),
    do:
      Scope.run(scope, fn ->
        Repo.all(from d in Did, where: d.tenant_id == ^tid, order_by: d.number)
      end)

  def get!(%Scope{kind: :platform}, id), do: Repo.get!(Did, id)

  def get!(%Scope{kind: :tenant, tenant_id: tid} = scope, id),
    do:
      Scope.run(scope, fn ->
        Repo.one!(from d in Did, where: d.id == ^id and d.tenant_id == ^tid)
      end)

  def change(%Did{} = did \\ %Did{}, attrs \\ %{}), do: Did.platform_changeset(did, attrs)
  def change_destination(%Did{} = did, attrs \\ %{}), do: Did.destination_changeset(did, attrs)

  ## Platform

  def create(%Scope{kind: :platform} = scope, attrs, actor) do
    Scope.run(scope, fn ->
      %Did{}
      |> Did.platform_changeset(attrs)
      |> check_alias()
      |> Changes.insert(actor, "did.create")
    end)
    |> announce()
  end

  @doc "Moving a number to another tenant (or none) clears its destination; its backup numbers move with it."
  def update(%Scope{kind: :platform} = scope, %Did{} = did, attrs, actor) do
    old_tenant = did.tenant_id

    Scope.run(scope, fn ->
      cs = did |> Did.platform_changeset(attrs) |> check_alias()

      cs =
        if Ecto.Changeset.get_change(cs, :tenant_id, old_tenant) != old_tenant,
          do: clear_destination(cs),
          else: cs

      with {:ok, did} <- Changes.update(cs, actor, "did.update") do
        Repo.update_all(from(a in Did, where: a.alias_of_id == ^did.id),
          set: [tenant_id: did.tenant_id]
        )

        {:ok, did}
      end
    end)
    |> announce(old_tenant)
  end

  def delete(%Scope{kind: :platform} = scope, %Did{} = did, actor),
    do:
      Scope.run(scope, fn -> Changes.delete(did, actor, "did.delete", %{number: did.number}) end)
      |> announce()

  ## Tenant

  def set_destination(
        %Scope{kind: :tenant, tenant_id: tid} = scope,
        %Did{tenant_id: tid, alias_of_id: nil} = did,
        attrs,
        actor
      ) do
    Scope.run(scope, fn ->
      cs = Did.destination_changeset(did, attrs)

      cs = cs |> Did.destination_changeset(attrs) |> own_extension(tid)
      Changes.update(cs, actor, "did.destination")
    end)
    |> announce()
  end

  def set_destination(%Scope{kind: :tenant}, %Did{alias_of_id: id}, _attrs, _actor)
      when not is_nil(id),
      do: {:error, :backup_number}

  defp own_extension(cs, tid) do
    ext_id = Ecto.Changeset.get_field(cs, :destination_id)

    if Ecto.Changeset.get_field(cs, :destination_type) != "extension" or
         (ext_id &&
            Repo.exists?(from e in Extension, where: e.id == ^ext_id and e.tenant_id == ^tid)),
       do: cs,
       else: Ecto.Changeset.add_error(cs, :destination_id, "not an extension of this tenant")
  end

  # A backup number points at a main number of the same tenant, which is not itself a backup.
  defp check_alias(cs) do
    case Ecto.Changeset.get_field(cs, :alias_of_id) do
      nil ->
        cs

      main_id ->
        case Repo.get(Did, main_id) do
          %Did{alias_of_id: nil, tenant_id: tid} when main_id != cs.data.id ->
            cs |> Ecto.Changeset.put_change(:tenant_id, tid) |> clear_destination()

          _ ->
            Ecto.Changeset.add_error(cs, :alias_of_id, "must be a main number")
        end
    end
  end

  defp clear_destination(cs),
    do:
      Ecto.Changeset.change(cs,
        destination_type: nil,
        destination_id: nil,
        destination_number: nil
      )

  defp announce(result, also_tenant \\ nil)

  defp announce({:ok, did} = ok, also_tenant) do
    for tid <- Enum.uniq([did.tenant_id, also_tenant]), do: Changes.announce(ok, tid, "dids")
    ok
  end

  defp announce(other, _), do: other
end
