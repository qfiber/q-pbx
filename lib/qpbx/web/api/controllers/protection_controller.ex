defmodule QPBX.Web.Api.ProtectionController do
  @moduledoc "SIP protection (platform keys): the edge's limits and its current bans; fraud protection."
  use QPBX.Web, :api_controller
  alias QPBX.{Edge, Telephony}
  alias QPBX.Edge.{Ban, Settings}
  alias QPBX.Telephony.Fraud

  @settings Schemas.of(Settings, "ProtectionSettings")
  @ban Schemas.of(Ban, "Ban")
  @fraud Schemas.of(Fraud.Settings, "FraudSettings")
  @block Schemas.of(Fraud.Block, "FraudBlock")

  def operation(:show),
    do: op("Protection", "SIP protection settings", "read", :platform, response: @settings)

  def operation(:update),
    do:
      op("Protection", "Change SIP protection (applied within seconds)", "write", :platform,
        body: Schemas.input(Settings, "ProtectionSettingsInput"),
        response: @settings
      )

  def operation(:bans),
    do:
      op(
        "Protection",
        "Active bans, newest first (all of them: next_cursor is null)",
        "read",
        :platform,
        response: {:list, @ban}
      )

  def operation(:lift),
    do:
      op("Protection", "Lift a ban (key: an address, or address|port)", "write", :platform,
        response: nil
      )

  def operation(:fraud),
    do: op("Protection", "Fraud protection settings", "read", :platform, response: @fraud)

  def operation(:update_fraud),
    do:
      op("Protection", "Change fraud protection", "write", :platform,
        body: Schemas.input(Fraud.Settings, "FraudSettingsInput"),
        response: @fraud
      )

  def operation(:blocks),
    do:
      op("Protection", "Tenants blocked by fraud protection", "read", :platform,
        params: Page.params(),
        response: {:list, @block}
      )

  def operation(:unblock),
    do: op("Protection", "Lift a fraud block", "write", :platform, response: nil)

  def show(conn, _), do: data(conn, Edge.get_settings())
  def update(conn, params), do: reply(conn, Edge.update_settings(params, conn.assigns.api_key))

  # Bans are keyed by address and expire within hours: one list, no pages.
  def bans(conn, _), do: json(conn, %{data: Schemas.render(Edge.list_bans()), next_cursor: nil})

  def lift(conn, %{"key" => key}), do: reply(conn, Edge.lift_ban(key, conn.assigns.api_key))
  def fraud(conn, _), do: data(conn, Telephony.fraud_settings())

  def update_fraud(conn, params),
    do: reply(conn, Telephony.update_fraud_settings(params, conn.assigns.api_key))

  def blocks(conn, params), do: paged(conn, Telephony.list_fraud_blocks(), params)

  def unblock(conn, %{"id" => id}),
    do: reply(conn, Telephony.lift_fraud_block(id, conn.assigns.api_key), 204)
end
