defmodule QPBX.Integrations do
  @moduledoc """
  Public API of the integrations area: outbound requests to tenant-chosen addresses and
  webhooks (later: flows, CRM adapters). See `lib/qpbx/integrations/README.md`.
  """
  use Boundary,
    deps: [QPBX.Repo, QPBX.Core, QPBX.Events],
    exports: [
      Address,
      Webhooks.Endpoint,
      Webhooks.Delivery,
      Webhooks.Dispatcher,
      Webhooks.Signature
    ]

  alias QPBX.Integrations.{OutboundHTTP, Webhooks}

  @doc "An HTTP request to an address a tenant chose, with every safety check (`OutboundHTTP`)."
  defdelegate request(method, url, opts \\ []), to: OutboundHTTP

  @doc "Checks an address without sending anything (`OutboundHTTP.check_destination/1`)."
  defdelegate check_destination(url), to: OutboundHTTP

  @doc """
  A bus event as webhooks and the event stream carry it: `{tenant_id, type, message}`
  (`message`: `%{id, type, version, created_at, tenant_id, data}`), or nil.
  """
  defdelegate event_message(event), to: Webhooks.Event, as: :message

  @doc "The bus event modules webhooks and the event stream carry."
  defdelegate event_sources(), to: Webhooks.Event, as: :sources

  ## Webhooks (tenant scope; see QPBX.Integrations.Webhooks)

  defdelegate webhook_event_types(), to: Webhooks.Event, as: :types
  defdelegate list_webhooks(scope), to: Webhooks, as: :list
  defdelegate get_webhook(scope, id), to: Webhooks, as: :get

  defdelegate change_webhook(endpoint \\ %Webhooks.Endpoint{}, attrs \\ %{}),
    to: Webhooks,
    as: :change

  @doc "Creates an endpoint: `{:ok, endpoint, secret}`, the secret shown once."
  defdelegate create_webhook(scope, attrs, actor), to: Webhooks, as: :create
  defdelegate update_webhook(scope, endpoint, attrs, actor), to: Webhooks, as: :update
  defdelegate delete_webhook(scope, endpoint, actor), to: Webhooks, as: :delete
  @doc "A new secret: `{:ok, endpoint, secret}`; the old one stops at once."
  defdelegate rotate_webhook_secret(scope, endpoint, actor), to: Webhooks, as: :rotate_secret

  defdelegate list_webhook_deliveries(scope, endpoint, limit \\ 50, before \\ nil),
    to: Webhooks,
    as: :deliveries

  defdelegate get_webhook_delivery(scope, id), to: Webhooks, as: :get_delivery
  defdelegate resend_webhook_delivery(scope, delivery, actor), to: Webhooks, as: :resend
end
