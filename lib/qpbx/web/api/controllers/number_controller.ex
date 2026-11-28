defmodule QPBX.Web.Api.NumberController do
  @moduledoc """
  Phone numbers (DIDs). Platform keys add, assign, change and remove them; tenant keys see
  their own and point them at a destination. Numbers are E.164.
  """
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Core.Did

  @did Schemas.of(Did, "Number")

  def operation(:index),
    do:
      op("Numbers", "List numbers (a tenant key: its own)", "read", :any,
        params: Page.params(),
        response: {:list, @did}
      )

  def operation(:show), do: op("Numbers", "Get a number", "read", :any, response: @did)

  def operation(:create),
    do:
      op("Numbers", "Add a number at a carrier trunk", "write", :platform,
        body: Schemas.input(Did, "NumberInput", ~w(number trunk_id)),
        status: 201,
        response: @did
      )

  def operation(:update),
    do:
      op(
        "Numbers",
        "Change a number (tenant_id assigns it; moving clears its destination)",
        "write",
        :platform,
        body: Schemas.input(Did, "NumberInput"),
        response: @did
      )

  def operation(:delete), do: op("Numbers", "Remove a number", "write", :platform, response: nil)

  def operation(:destination),
    do:
      op(
        "Numbers",
        "Point a number at one of the tenant's extensions or an outside number",
        "write",
        :tenant,
        body: %{
          type: "object",
          required: ["destination_type"],
          properties: %{
            destination_type: %{type: "string", enum: Did.destination_types()},
            destination_id: %{
              type: "string",
              format: "uuid",
              description: "the extension, for type extension"
            },
            destination_number: %{type: "string", description: "E.164, for type external"}
          }
        },
        response: @did
      )

  def index(conn, params), do: paged(conn, Core.list_dids(scope(conn)), params)
  def show(conn, %{"id" => id}), do: data(conn, Core.get_did!(scope(conn), id))

  def create(conn, params),
    do: reply(conn, Core.create_did(scope(conn), params, actor(conn)), 201)

  def update(conn, %{"id" => id} = p),
    do:
      reply(
        conn,
        Core.update_did(
          scope(conn),
          Core.get_did!(scope(conn), id),
          Map.drop(p, ["id"]),
          actor(conn)
        )
      )

  def delete(conn, %{"id" => id}),
    do:
      reply(conn, Core.delete_did(scope(conn), Core.get_did!(scope(conn), id), actor(conn)), 204)

  def destination(conn, %{"id" => id} = p),
    do:
      reply(
        conn,
        Core.set_did_destination(
          scope(conn),
          Core.get_did!(scope(conn), id),
          Map.drop(p, ["id"]),
          actor(conn)
        )
      )

  defp scope(conn), do: conn.assigns.current_scope
  defp actor(conn), do: conn.assigns.api_key
end
