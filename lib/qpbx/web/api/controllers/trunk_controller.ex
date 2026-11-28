defmodule QPBX.Web.Api.TrunkController do
  @moduledoc "Carrier trunks shared by the platform (platform keys). Passwords are never returned."
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Core.{Trunk, TrunkAddress}

  @trunk Schemas.of(Trunk, "Trunk")
  @input Schemas.input(Trunk, "TrunkInput", ~w(name auth_mode), %{
           password: %{type: "string", writeOnly: true},
           addresses: %{
             type: "array",
             items: Schemas.input(TrunkAddress, "TrunkAddressInput", ["host"])
           }
         })

  def operation(:index),
    do:
      op("Trunks", "List trunks", "read", :platform,
        params: Page.params(),
        response: {:list, @trunk}
      )

  def operation(:show), do: op("Trunks", "Get a trunk", "read", :platform, response: @trunk)

  def operation(:create),
    do:
      op("Trunks", "Create a trunk", "write", :platform,
        body: @input,
        status: 201,
        response: @trunk
      )

  def operation(:update),
    do:
      op("Trunks", "Change a trunk (addresses, when given, replace the list)", "write", :platform,
        body: @input,
        response: @trunk
      )

  def operation(:delete),
    do:
      op("Trunks", "Delete a trunk (refused while a route uses it)", "write", :platform,
        response: nil
      )

  def index(conn, params), do: paged(conn, Core.list_trunks(scope(conn)), params)
  def show(conn, %{"id" => id}), do: data(conn, Core.get_trunk!(scope(conn), id))

  def create(conn, params),
    do: reply(conn, Core.create_trunk(scope(conn), params, conn.assigns.api_key), 201)

  def update(conn, %{"id" => id} = params),
    do:
      reply(
        conn,
        Core.update_trunk(
          scope(conn),
          Core.get_trunk!(scope(conn), id),
          params,
          conn.assigns.api_key
        )
      )

  def delete(conn, %{"id" => id}),
    do:
      reply(
        conn,
        Core.delete_trunk(scope(conn), Core.get_trunk!(scope(conn), id), conn.assigns.api_key),
        204
      )

  defp scope(conn), do: conn.assigns.current_scope
end
