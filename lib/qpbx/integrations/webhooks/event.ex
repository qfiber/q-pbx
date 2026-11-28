defmodule QPBX.Integrations.Webhooks.Event do
  @moduledoc """
  Bus events as webhook events: the type name and the JSON payload
  `{"id", "type", "version", "created_at", "tenant_id", "data"}`. `id` is the same for every
  endpoint and every resend of one event, so receivers can drop repeats.
  """
  alias QPBX.Events.{CallEvent, ExtensionRegistration, LimitReached, VoicemailReceived}

  @types for(t <- CallEvent.types(), do: "call." <> t) ++
           ~w(extension.registered extension.unregistered voicemail.received limit.reached)

  @doc "The event types an endpoint can subscribe to (the ones Q-PBX emits so far)."
  def types, do: @types

  @doc "The bus events webhooks are made from."
  def sources, do: [CallEvent, ExtensionRegistration, VoicemailReceived, LimitReached]

  @doc "`{type, tenant_id, data}` for a bus event, or nil when no webhook carries it."
  def from(%CallEvent{type: t} = e), do: {"call." <> t, e.tenant_id, data(e, [:type])}

  def from(%ExtensionRegistration{type: t} = e),
    do: {"extension." <> t, e.tenant_id, data(e, [:type])}

  def from(%VoicemailReceived{} = e), do: {"voicemail.received", e.tenant_id, data(e, [])}
  def from(%LimitReached{} = e), do: {"limit.reached", e.tenant_id, data(e, [])}
  def from(_), do: nil

  @doc "The JSON body of one event."
  def payload(id, type, version, tenant_id, data, at),
    do:
      Jason.encode!(%{
        id: id,
        type: type,
        version: version,
        created_at: at,
        tenant_id: tenant_id,
        data: data
      })

  defp data(e, drop), do: e |> Map.from_struct() |> Map.drop([:version, :tenant_id, :at | drop])
end
