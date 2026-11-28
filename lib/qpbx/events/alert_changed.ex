defmodule QPBX.Events.AlertChanged do
  @moduledoc """
  An alert was raised, repeated, acknowledged or resolved (`event`). Feeds the event stream and
  flows later; notifications are sent by `QPBX.Notify` itself. Version 1.
  """
  @enforce_keys [:alert_id, :event, :at]
  defstruct version: 1,
            id: nil,
            alert_id: nil,
            tenant_id: nil,
            event: nil,
            kind: nil,
            category: nil,
            severity: nil,
            at: nil

  def topic, do: "alerts"
end
