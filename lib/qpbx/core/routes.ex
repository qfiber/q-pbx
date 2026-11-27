defmodule QPBX.Core.Routes do
  @moduledoc """
  A tenant's outbound routes with their ordered trunks (carrier failover). A route may use the
  tenant's own trunks and the platform's shared ones.
  """
  import Ecto.Query
  alias QPBX.Core.{Changes, OutboundRoute, RouteTrunk, Scope, Trunk}
  alias QPBX.Repo

  def list(%Scope{kind: :tenant, tenant_id: tid} = scope) do
    Scope.run(scope, fn ->
      Repo.all(
        from r in OutboundRoute,
          where: r.tenant_id == ^tid,
          order_by: [r.position, r.name],
          preload: :route_trunks
      )
    end)
    |> Enum.map(&with_trunk_ids/1)
  end

  def get!(%Scope{kind: :tenant, tenant_id: tid} = scope, id) do
    Scope.run(scope, fn ->
      Repo.one!(
        from r in OutboundRoute,
          where: r.id == ^id and r.tenant_id == ^tid,
          preload: :route_trunks
      )
    end)
    |> with_trunk_ids()
  end

  def change(%OutboundRoute{} = route \\ %OutboundRoute{}, attrs \\ %{}),
    do: OutboundRoute.changeset(route, attrs)

  def create(%Scope{kind: :tenant, tenant_id: tid} = scope, attrs, actor),
    do:
      save(
        scope,
        OutboundRoute.changeset(%OutboundRoute{tenant_id: tid}, attrs),
        actor,
        "route.create"
      )

  def update(
        %Scope{kind: :tenant, tenant_id: tid} = scope,
        %OutboundRoute{tenant_id: tid} = route,
        attrs,
        actor
      ),
      do: save(scope, OutboundRoute.changeset(route, attrs), actor, "route.update")

  def delete(
        %Scope{kind: :tenant, tenant_id: tid} = scope,
        %OutboundRoute{tenant_id: tid} = route,
        actor
      ) do
    Scope.run(scope, fn ->
      Changes.delete(Ecto.Changeset.change(route), actor, "route.delete", %{name: route.name})
    end)
    |> Changes.announce(tid, "routes")
  end

  defp save(%Scope{tenant_id: tid} = scope, cs, actor, action) do
    trunk_ids = Ecto.Changeset.get_field(cs, :trunk_ids)
    # Checked before the scoped write: row-level security would hide the platform's trunks.
    allowed =
      Repo.all(
        from t in Trunk,
          where: t.id in ^trunk_ids and (is_nil(t.tenant_id) or t.tenant_id == ^tid),
          select: t.id
      )

    cs =
      if length(allowed) == length(Enum.uniq(trunk_ids)),
        do: cs,
        else: Ecto.Changeset.add_error(cs, :trunk_ids, "unknown trunk")

    op = if cs.data.id, do: &Changes.update/3, else: &Changes.insert/3

    Scope.run(scope, fn ->
      with {:ok, route} <- op.(cs, actor, action) do
        Repo.delete_all(from rt in RouteTrunk, where: rt.route_id == ^route.id)

        put_trunks(route, tid, trunk_ids)
        {:ok, %{route | trunk_ids: Enum.uniq(trunk_ids)}}
      end
    end)
    |> Changes.announce(tid, "routes")
  end

  defp put_trunks(route, tid, trunk_ids) do
    for {trunk_id, i} <- trunk_ids |> Enum.uniq() |> Enum.with_index() do
      Repo.insert!(%RouteTrunk{
        tenant_id: tid,
        route_id: route.id,
        trunk_id: trunk_id,
        position: i
      })
    end
  end

  defp with_trunk_ids(route),
    do: %{route | trunk_ids: Enum.map(route.route_trunks, & &1.trunk_id)}
end
