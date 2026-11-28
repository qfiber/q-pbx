defmodule QPBX.Integrations.Webhooks.Event do
  @moduledoc """
  Bus events as webhook events: the type name and the JSON payload
  `{"id", "type", "version", "created_at", "tenant_id", "data"}`. `id` is the same for every
  endpoint and every resend of one event, so receivers can drop repeats.
  """
  alias QPBX.Events.{
    CallEvent,
    ExtensionRegistration,
    LimitReached,
    UsageThresholdReached,
    VoicemailReceived
  }

  @types for(t <- CallEvent.types(), do: "call." <> t) ++
           ~w(extension.registered extension.unregistered voicemail.received limit.reached
              usage.threshold_reached)

  @doc "The event types an endpoint can subscribe to (the ones Q-PBX emits so far)."
  def types, do: @types

  @doc "The bus events webhooks are made from."
  def sources,
    do: [CallEvent, ExtensionRegistration, VoicemailReceived, LimitReached, UsageThresholdReached]

  @doc "`{type, tenant_id, data}` for a bus event, or nil when no webhook carries it."
  def from(%CallEvent{type: t} = e), do: {"call." <> t, e.tenant_id, data(e, [:type])}

  def from(%ExtensionRegistration{type: t} = e),
    do: {"extension." <> t, e.tenant_id, data(e, [:type])}

  def from(%VoicemailReceived{} = e), do: {"voicemail.received", e.tenant_id, data(e, [])}
  def from(%LimitReached{} = e), do: {"limit.reached", e.tenant_id, data(e, [])}

  def from(%UsageThresholdReached{} = e),
    do: {"usage.threshold_reached", e.tenant_id, data(e, [])}

  def from(_), do: nil

  @doc """
  The message for one bus event, as webhooks send it and the event stream pushes it:
  `{tenant_id, type, map}`, or nil when no webhook carries the event.
  """
  def message(event) do
    case from(event) do
      {type, tid, data} when is_binary(tid) ->
        {tid, type,
         %{
           id: Map.get(event, :id) || Ecto.UUID.generate(),
           type: type,
           version: Map.get(event, :version, 1),
           created_at: Map.get(event, :at) || DateTime.utc_now(),
           tenant_id: tid,
           data: data
         }}

      _ ->
        nil
    end
  end

  defp data(e, drop),
    do: e |> Map.from_struct() |> Map.drop([:id, :version, :tenant_id, :at | drop])
end
