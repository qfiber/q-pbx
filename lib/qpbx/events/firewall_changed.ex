defmodule QPBX.Events.FirewallChanged do
  @moduledoc "Firewall entries changed; every node re-applies its sets. Version 1."
  @enforce_keys [:at]
  defstruct version: 1, at: nil, reason: nil

  def topic, do: "firewall"
end
