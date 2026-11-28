defmodule QPBX.Events.CallEvent do
  @moduledoc """
  A step in a call, published by its call process in order. `type` is the webhook's name
  without the `call.` prefix:

  - `started`: routed (`direction` internal, inbound or outbound; `from`, `to`)
  - `ringing`: the target is ringing (`target`)
  - `answered`: connected to the target (`target`)
  - `transferred`: moved to a new destination (`target`; `to` is the new number)
  - `ended`: hung up (`disposition` answered, voicemail, busy, no_answer or failed; `cause`,
    `duration` and `billsec` in seconds)
  - `missed`: ended without being answered while it rang extensions (`extension_ids`), after
    `ended`

  `call_id` is the caller's channel (the same for every step); `target` is
  `%{type: "extension", extension_id, number}`, `%{type: "external", number}` (E.164) or
  `%{type: "other"}`. `extension_id` is the calling extension, when a phone called. Version 1.
  """
  @types ~w(started ringing answered transferred ended missed)

  @enforce_keys [:type, :tenant_id, :call_id, :at]
  defstruct version: 1,
            type: nil,
            tenant_id: nil,
            call_id: nil,
            direction: nil,
            from: nil,
            from_name: nil,
            to: nil,
            extension_id: nil,
            target: nil,
            disposition: nil,
            cause: nil,
            duration: nil,
            billsec: nil,
            extension_ids: [],
            at: nil

  def types, do: @types
  def topic, do: "calls"
end
