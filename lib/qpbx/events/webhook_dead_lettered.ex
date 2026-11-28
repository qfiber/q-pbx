defmodule QPBX.Events.WebhookDeadLettered do
  @moduledoc """
  A webhook delivery got no 2xx answer within 24 hours and was given up. Feeds the
  "webhook dead-lettered" alert (3-9). Version 1.
  """
  @enforce_keys [:tenant_id, :endpoint_id, :delivery_id, :at]
  defstruct version: 1,
            tenant_id: nil,
            endpoint_id: nil,
            delivery_id: nil,
            event_type: nil,
            url: nil,
            at: nil

  def topic, do: "webhooks"
end
