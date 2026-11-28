defmodule QPBX.Events.TrunkStatusChanged do
  @moduledoc """
  A trunk went down or came back: `up` false when every address stopped answering Kamailio's
  OPTIONS (IP trunks) or the registration failed (registration trunks). `tenant_id` nil: a
  shared trunk. Version 1.
  """
  @enforce_keys [:trunk_id, :up, :at]
  defstruct version: 1, trunk_id: nil, tenant_id: nil, name: nil, up: true, reason: nil, at: nil

  def topic, do: "trunk_status"
end
