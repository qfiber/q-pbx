defmodule QPBX.Events.VoicemailChanged do
  @moduledoc """
  An extension's message counts changed (a message left, listened to or deleted): the
  message-waiting light (`QPBX.Edge.Presence`). Version 1.
  """
  @enforce_keys [:tenant_id, :extension_id, :new, :saved, :at]
  defstruct version: 1, tenant_id: nil, extension_id: nil, new: 0, saved: 0, at: nil

  def topic, do: "mwi"
end
