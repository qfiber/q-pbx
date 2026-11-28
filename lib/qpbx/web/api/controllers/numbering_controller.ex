defmodule QPBX.Web.Api.NumberingController do
  @moduledoc """
  Number classes and emergency routes (platform keys), and the number format: the platform's
  default with a platform key, the tenant's own with a tenant key.
  """
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Core.{EmergencyRoute, NumberClass, NumberRule}

  @class Schemas.of(NumberClass, "NumberClass")
  @emergency Schemas.of(EmergencyRoute, "EmergencyRoute")
  @rule Schemas.of(NumberRule, "NumberFormat")

  def operation(:classes),
    do:
      op("Numbering", "List number classes", "read", :platform,
        params: Page.params(),
        response: {:list, @class}
      )

  def operation(:create_class),
    do:
      op("Numbering", "Add a number class", "write", :platform,
        body: Schemas.input(NumberClass, "NumberClassInput", ~w(prefix class)),
        status: 201,
        response: @class
      )

  def operation(:delete_class),
    do: op("Numbering", "Delete a number class", "write", :platform, response: nil)

  def operation(:emergency),
    do:
      op("Numbering", "List emergency routes", "read", :platform,
        params: Page.params(),
        response: {:list, @emergency}
      )

  def operation(:create_emergency),
    do:
      op("Numbering", "Add an emergency route", "write", :platform,
        body: Schemas.input(EmergencyRoute, "EmergencyRouteInput", ~w(number trunk_id)),
        status: 201,
        response: @emergency
      )

  def operation(:delete_emergency),
    do: op("Numbering", "Delete an emergency route", "write", :platform, response: nil)

  def operation(:format),
    do:
      op(
        "Numbering",
        "The number format in force (platform default, or the tenant's)",
        "read",
        :any,
        response: @rule
      )

  def operation(:put_format),
    do:
      op("Numbering", "Set the number format", "write", :any,
        body: Schemas.input(NumberRule, "NumberFormatInput"),
        response: @rule
      )

  def operation(:reset_format),
    do:
      op("Numbering", "Go back to the platform's number format", "write", :tenant, response: nil)

  def classes(conn, params), do: paged(conn, Core.list_number_classes(), params)

  def create_class(conn, params),
    do: reply(conn, Core.create_number_class(scope(conn), params, actor(conn)), 201)

  def delete_class(conn, %{"id" => id}),
    do: reply(conn, Core.delete_number_class(scope(conn), id, actor(conn)), 204)

  def emergency(conn, params), do: paged(conn, Core.list_emergency_routes(), params)

  def create_emergency(conn, params),
    do: reply(conn, Core.create_emergency_route(scope(conn), params, actor(conn)), 201)

  def delete_emergency(conn, %{"id" => id}),
    do: reply(conn, Core.delete_emergency_route(scope(conn), id, actor(conn)), 204)

  def format(conn, _), do: data(conn, Core.number_rule(scope(conn)))

  def put_format(conn, params),
    do: reply(conn, Core.put_number_rule(scope(conn), params, actor(conn)))

  def reset_format(conn, _),
    do: reply(conn, Core.reset_number_rule(scope(conn), actor(conn)), 204)

  defp scope(conn), do: conn.assigns.current_scope
  defp actor(conn), do: conn.assigns.api_key
end
