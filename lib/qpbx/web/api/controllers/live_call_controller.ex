defmodule QPBX.Web.Api.LiveCallController do
  @moduledoc """
  Click-to-call and live calls (tenant keys with the `calls` scope): ring an extension, then
  call a number from it; list, hang up and transfer the tenant's live calls.
  """
  use QPBX.Web, :api_controller
  alias QPBX.Telephony

  @live %{
    "x-name": "LiveCall",
    type: "object",
    properties: %{
      call_id: %{type: "string", format: "uuid"},
      direction: %{type: ["string", "null"], enum: ["internal", "inbound", "outbound", nil]},
      from: %{type: ["string", "null"]},
      to: %{type: ["string", "null"]},
      extension_id: %{
        type: ["string", "null"],
        format: "uuid",
        description: "the calling extension"
      },
      answered: %{type: "boolean"},
      started_at: %{type: "string", format: "date-time"}
    }
  }

  @to %{
    type: "string",
    description: "an extension number, an E.164 number or a feature code",
    example: "+97221234567"
  }

  def operation(:create),
    do:
      op(
        "Live calls",
        "Click-to-call: ring the extension's phones (showing the number), then call the number from it when one answers. The answer's call_id is the call's id in call.* events.",
        "calls",
        :tenant,
        body: %{
          type: "object",
          required: ["extension_id", "to"],
          properties: %{extension_id: %{type: "string", format: "uuid"}, to: @to}
        },
        status: 202,
        response: %{type: "object", properties: %{call_id: %{type: "string", format: "uuid"}}}
      )

  def operation(:index),
    do:
      op("Live calls", "The tenant's calls in progress", "calls", :tenant,
        response: {:list, @live}
      )

  def operation(:hangup), do: op("Live calls", "Hang up a call", "calls", :tenant, response: nil)

  def operation(:transfer),
    do:
      op(
        "Live calls",
        "Blind transfer: the caller's side goes to the new destination, the other side is released",
        "calls",
        :tenant,
        body: %{type: "object", required: ["to"], properties: %{to: @to}},
        response: nil
      )

  def create(conn, %{"extension_id" => ext_id, "to" => to}) do
    with {:ok, call_id} <-
           Telephony.originate(conn.assigns.current_scope, ext_id, to, conn.assigns.api_key),
         do: conn |> put_status(202) |> json(%{data: %{call_id: call_id}})
  end

  def create(_conn, _), do: {:error, {:bad_request, "extension_id and to are required"}}

  def index(conn, _),
    do:
      json(conn, %{
        data:
          Telephony.list_live_calls(conn.assigns.current_scope)
          |> Enum.map(&Map.delete(&1, :tenant_id)),
        next_cursor: nil
      })

  def hangup(conn, %{"id" => id}),
    do: reply(conn, Telephony.hangup_call(conn.assigns.current_scope, id, conn.assigns.api_key))

  def transfer(conn, %{"id" => id, "to" => to}),
    do:
      reply(
        conn,
        Telephony.transfer_call(conn.assigns.current_scope, id, to, conn.assigns.api_key)
      )

  def transfer(_conn, _), do: {:error, {:bad_request, "to is required"}}
end
