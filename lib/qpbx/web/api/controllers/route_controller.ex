defmodule QPBX.Web.Api.RouteController do
  @moduledoc "Outbound routes (tenant keys): prefixes, destination class, trunks in order."
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Core.OutboundRoute

  @route Schemas.of(OutboundRoute, "Route")
  @input Schemas.input(OutboundRoute, "RouteInput", ~w(name destination_class trunk_ids))

  def operation(:index),
    do:
      op("Routes", "List outbound routes", "read", :tenant,
        params: Page.params(),
        response: {:list, @route}
      )

  def operation(:show), do: op("Routes", "Get a route", "read", :tenant, response: @route)

  def operation(:create),
    do:
      op("Routes", "Create a route (trunk_ids in failover order)", "write", :tenant,
        body: @input,
        status: 201,
        response: @route
      )

  def operation(:update),
    do: op("Routes", "Change a route", "write", :tenant, body: @input, response: @route)

  def operation(:delete), do: op("Routes", "Delete a route", "write", :tenant, response: nil)

  def index(conn, params), do: paged(conn, Core.list_routes(scope(conn)), params)
  def show(conn, %{"id" => id}), do: data(conn, Core.get_route!(scope(conn), id))

  def create(conn, params) do
    with {:ok, r} <- Core.create_route(scope(conn), params, actor(conn)),
         do: data(conn, Core.get_route!(scope(conn), r.id), 201)
  end

  def update(conn, %{"id" => id} = params) do
    route = Core.get_route!(scope(conn), id)

    with {:ok, _} <- Core.update_route(scope(conn), route, Map.drop(params, ["id"]), actor(conn)),
         do: data(conn, Core.get_route!(scope(conn), id))
  end

  def delete(conn, %{"id" => id}),
    do:
      reply(
        conn,
        Core.delete_route(scope(conn), Core.get_route!(scope(conn), id), actor(conn)),
        204
      )

  defp scope(conn), do: conn.assigns.current_scope
  defp actor(conn), do: conn.assigns.api_key
end
