defmodule QPBX.Events.ExtensionRegistration do
  @moduledoc """
  A device of an extension registered or stopped being registered, as Kamailio reports it.
  `type` is `registered` or `unregistered` (webhooks `extension.registered` and
  `extension.unregistered`); `reason` for unregistered: `unregister` (the phone said so) or
  `expired` (it stopped renewing). One per device login (`device`): an extension with several
  devices can be unregistered on one and still registered on another. `contact` is the
  address it registered from. Version 1.
  """
  @enforce_keys [:type, :tenant_id, :extension_id, :device, :at]
  defstruct version: 1,
            type: nil,
            tenant_id: nil,
            extension_id: nil,
            extension: nil,
            device: nil,
            contact: nil,
            user_agent: nil,
            reason: nil,
            at: nil

  def topic, do: "registrations"
end
