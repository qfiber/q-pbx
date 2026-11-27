defmodule QPBX.Events.SipCredentialsChanged do
  @moduledoc "SIP credentials of a tenant were added, changed or removed; Kamailio reloads them. Version 1."
  @enforce_keys [:tenant_id, :at]
  defstruct version: 1, tenant_id: nil, at: nil

  def topic, do: "sip_credentials"
end
