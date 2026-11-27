defmodule QPBX.Events.VoicemailReceived do
  @moduledoc """
  A caller left a message in an extension's mailbox. Feeds the `voicemail.received` webhook
  (phase 3). Version 1.
  """
  @enforce_keys [:tenant_id, :voicemail_id, :extension_id, :at]
  defstruct version: 1,
            tenant_id: nil,
            voicemail_id: nil,
            extension_id: nil,
            caller_number: nil,
            caller_name: nil,
            duration: 0,
            at: nil

  def topic, do: "voicemail"
end
