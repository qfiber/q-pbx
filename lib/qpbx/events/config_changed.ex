defmodule QPBX.Events.ConfigChanged do
  @moduledoc """
  Telephony configuration changed: `kind` is "extensions", "devices", "trunks", "dids",
  "routes", "emergency_routes", "number_rules" or "number_classes". `tenant_id` is nil for
  platform-wide changes. Call control drops its cached copy; the edge reloads trunks. Version 1.
  """
  @enforce_keys [:kind, :at]
  defstruct version: 1, tenant_id: nil, kind: nil, at: nil

  def topic, do: "config"
end
