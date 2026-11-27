defmodule QPBX.Events.CallState do
  @moduledoc """
  An extension's part in a call changed (busy lamps): `state` is "early" (ringing),
  "confirmed" (talking) or "terminated"; `direction` is "initiator" (the extension called) or
  "recipient" (it is being called); `peer` is the other party as shown. `call_id` is unique per
  call and extension. Version 1.
  """
  @enforce_keys [:tenant_id, :domain, :extension, :call_id, :state, :direction, :at]
  defstruct version: 1,
            tenant_id: nil,
            domain: nil,
            extension: nil,
            peer: nil,
            call_id: nil,
            state: nil,
            direction: nil,
            at: nil

  def topic, do: "call_state"
end
