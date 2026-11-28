defmodule QPBX.Integrations do
  @moduledoc """
  Public API of the integrations area: outbound requests to tenant-chosen addresses (later:
  webhooks, flows, CRM adapters). See `lib/qpbx/integrations/README.md`.
  """
  use Boundary, deps: [], exports: [Address]

  alias QPBX.Integrations.OutboundHTTP

  @doc "An HTTP request to an address a tenant chose, with every safety check (`OutboundHTTP`)."
  defdelegate request(method, url, opts \\ []), to: OutboundHTTP
end
