defmodule QPBX.Events do
  @moduledoc """
  Public API of the event bus: typed, versioned event structs on Phoenix.PubSub.
  Phoenix.PubSub reaches every node in the cluster. See `lib/qpbx/events/README.md`.
  """
  use Boundary,
    deps: [],
    exports: [
      CallState,
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

  @doc "Broadcasts an event struct on its topic (`event.__struct__.topic/0`)."
  def publish(%module{} = event),
    do: Phoenix.PubSub.broadcast(@pubsub, module.topic(), {:event, event})

  @doc "Subscribes the calling process to an event type; messages arrive as `{:event, struct}`."
  def subscribe(module) when is_atom(module),
    do: Phoenix.PubSub.subscribe(@pubsub, module.topic())
end
