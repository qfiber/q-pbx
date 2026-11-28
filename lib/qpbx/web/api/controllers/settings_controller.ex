defmodule QPBX.Web.Api.SettingsController do
  @moduledoc """
  Platform settings (platform keys): outgoing email and the sign-in human check; a test email.
  Passwords and secrets can be set but are never returned.
  """
  use QPBX.Web, :api_controller
  alias QPBX.{Core, Notify}
  alias QPBX.Core.PlatformSettings

  @settings Schemas.of(PlatformSettings, "PlatformSettings")

  def operation(:show),
    do:
      op(
        "Settings",
        "Platform settings (empty values use the installation's)",
        "read",
        :platform,
        response: @settings
      )

  def operation(:update),
    do:
      op(
        "Settings",
        "Change platform settings; applies at once (an empty password or secret keeps the saved one)",
        "admin",
        :platform,
        body: Schemas.input(PlatformSettings, "PlatformSettingsInput"),
        response: @settings
      )

  def operation(:test_email),
    do:
      op("Settings", "Send a test email now with the current settings", "admin", :platform,
        body: %{type: "object", required: ["to"], properties: %{to: %{type: "string"}}},
        response: nil
      )

  def show(conn, _), do: data(conn, Core.platform_settings())

  def update(conn, params),
    do: reply(conn, Core.update_platform_settings(params, conn.assigns.api_key))

  def test_email(conn, %{"to" => to}) when is_binary(to) do
    case Notify.send_test_email(String.trim(to)) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> reply(conn, {:error, {:bad_gateway, reason}})
    end
  end

  def test_email(conn, _), do: reply(conn, {:error, {:bad_request, "to is required"}})
end
