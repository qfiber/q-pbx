defmodule QPBX.Events.FraudAlert do
  @moduledoc """
  A velocity rule fired for a tenant: `rule` is "international_spike" or "quiet_hours";
  `blocked` says whether international calling was blocked. Version 1.
  """
  @enforce_keys [:tenant_id, :rule, :at]
  defstruct version: 1, tenant_id: nil, rule: nil, detail: nil, blocked: false, at: nil

  def topic, do: "fraud"
end
