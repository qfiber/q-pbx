defmodule QPBX.Events.TenantsChanged do
  @moduledoc "A tenant was created or changed (its SIP domain may be new); Kamailio reloads its domains. Version 1."
  @enforce_keys [:tenant_id, :at]
  defstruct version: 1, tenant_id: nil, at: nil

  def topic, do: "tenants"
end
