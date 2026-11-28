defmodule QPBX.Events do
  @moduledoc """
  Public API of the event bus: typed, versioned event structs on Phoenix.PubSub.
  Phoenix.PubSub reaches every node in the cluster. See `lib/qpbx/events/README.md`.
  """
  use Boundary,
    deps: [],
    exports: [
      CallState,
      CallEvent,
      ExtensionRegistration,
      WebhookDeadLettered,
      ApiKeysRevoked,
      ConfigChanged,
      FraudAlert,
      LimitReached,
      VoicemailReceived,
      VoicemailChanged,
      EdgeAlert,
      FirewallChanged,
      SessionsRevoked,
      SipCredentialsChanged,
      TenantsChanged
    ]

  @pubsub QPBX.PubSub

  @doc """
  Broadcasts an event struct on its topic (`event.__struct__.topic/0`). An event with an `id`
  field gets a new UUID there, so every consumer (webhooks, the event stream) names it the same.
  """
  def publish(%module{} = event) do
    event =
      if Map.get(event, :id, false) == nil, do: %{event | id: Ecto.UUID.generate()}, else: event

    Phoenix.PubSub.broadcast(@pubsub, module.topic(), {:event, event})
  end

  @doc "Subscribes the calling process to an event type; messages arrive as `{:event, struct}`."
  def subscribe(module) when is_atom(module),
    do: Phoenix.PubSub.subscribe(@pubsub, module.topic())
end
