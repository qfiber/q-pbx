defmodule QPBX.Web.Api.EventChannelTest do
  use QPBX.DataCase, async: false
  import Phoenix.ChannelTest
  import Ecto.Query, only: [from: 2]
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Events
  alias QPBX.Events.{CallEvent, ExtensionRegistration}
  alias QPBX.Web.Api.{EventChannel, EventSocket}

  @endpoint QPBX.Web.Endpoint
  @actor {:system, "test"}

  defp key(scope, scopes \\ ["read"]) do
    {:ok, key, token} = Core.create_api_key(scope, %{name: "stream", scopes: scopes}, @actor)
    {key, token}
  end

  defp stream(token, types \\ nil) do
    {:ok, socket} = connect(EventSocket, %{}, connect_info: %{auth_token: token})

    subscribe_and_join(
      socket,
      EventChannel,
      "events",
      if(types, do: %{"types" => types}, else: %{})
    )
  end

  defp call(tid, type),
    do: %CallEvent{
      type: type,
      tenant_id: tid,
      call_id: "c-#{type}",
      from: "101",
      to: "102",
      at: DateTime.utc_now()
    }

  setup do
    t = tenant_fixture()
    %{t: t, scope: Core.scope_for(user_fixture(t))}
  end

  test "a tenant's key streams its own tenant's events only, as webhooks carry them", %{
    t: t,
    scope: scope
  } do
    {_, token} = key(scope)
    {:ok, %{types: types}, _socket} = stream(token)
    assert "call.started" in types and "extension.registered" in types

    other = tenant_fixture()
    Events.publish(call(other.id, "started"))
    Events.publish(call(t.id, "started"))

    assert_push "event", %{
      type: "call.started",
      tenant_id: tid,
      id: id,
      data: %{call_id: "c-started", from: "101"}
    }

    assert tid == t.id and is_binary(id)
    refute_push "event", %{tenant_id: _}, 100
  end

  test "the stream and webhooks name an event with the same id" do
    e = call(Ecto.UUID.generate(), "ended")
    Events.subscribe(CallEvent)
    Events.publish(e)
    assert_receive {:event, %CallEvent{id: id} = published}
    assert {_, "call.ended", %{id: ^id}} = QPBX.Integrations.event_message(published)
  end

  test "filtered by event type; unknown types refused", %{t: t, scope: scope} do
    {_, token} = key(scope)
    {:ok, _, _} = stream(token, ["extension.registered"])
    Events.publish(call(t.id, "started"))

    Events.publish(%ExtensionRegistration{
      type: "registered",
      tenant_id: t.id,
      extension_id: Ecto.UUID.generate(),
      device: "101",
      at: DateTime.utc_now()
    })

    assert_push "event", %{type: "extension.registered", data: %{device: "101"}}
    refute_push "event", %{type: "call.started"}, 100

    {:ok, socket} = connect(EventSocket, %{}, connect_info: %{auth_token: token})

    assert {:error, %{reason: "unknown_types", types: ["fax.sent"]}} =
             join(socket, EventChannel, "events", %{"types" => ["fax.sent", "call.ended"]})

    assert {:error, %{reason: "bad_types"}} =
             join(socket, EventChannel, "events", %{"types" => []})
  end

  test "the endpoint reads the key from the handshake header (a socket option in Phoenix 1.8)" do
    # The other tests pass connect_info themselves; this checks the real endpoint passes it on.
    {_, _, opts} = Enum.find(@endpoint.__sockets__(), &(elem(&1, 0) == "/v1/socket"))
    assert opts[:auth_token] == true
    assert opts[:longpoll] == false
  end

  test "only the API stream skips the origin check; the portal's LiveView socket keeps it" do
    # Sobelow's cross-site WebSocket check is ignored for the API stream; this keeps /live safe.
    for {path, _, opts} <- @endpoint.__sockets__() do
      ws = opts[:websocket] || []

      if path == "/v1/socket",
        do: assert(ws[:check_origin] == false),
        else: refute(Keyword.has_key?(ws, :check_origin), path)
    end
  end

  test "refused: no key, a wrong key, no read scope, a platform key, an expired key", %{
    scope: scope
  } do
    assert :error = connect(EventSocket, %{}, connect_info: %{})
    assert :error = connect(EventSocket, %{}, connect_info: %{auth_token: "qpbx_wrong"})
    {_, calls_only} = key(scope, ["calls"])
    assert :error = connect(EventSocket, %{}, connect_info: %{auth_token: calls_only})
    {_, platform} = key(Core.scope_for(platform_admin_fixture()))
    assert :error = connect(EventSocket, %{}, connect_info: %{auth_token: platform})

    {k, expired} = key(scope)

    QPBX.Repo.update_all(from(x in Core.ApiKey, where: x.id == ^k.id),
      set: [expires_at: ~U[2020-01-01 00:00:00Z]]
    )

    assert :error = connect(EventSocket, %{}, connect_info: %{auth_token: expired})
  end

  test "revoking the key closes its streams at once; an expired key ends at the next check", %{
    scope: scope
  } do
    {k, token} = key(scope)
    {:ok, socket} = connect(EventSocket, %{}, connect_info: %{auth_token: token})
    assert EventSocket.id(socket) == "api_key_socket:" <> k.id
    @endpoint.subscribe(EventSocket.id(socket))
    {:ok, _} = Core.revoke_api_key(scope, k.id, @actor)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: "api_key_socket:" <> _}

    {k2, token2} = key(scope)
    {:ok, _, socket2} = stream(token2)
    Process.unlink(socket2.channel_pid)
    ref = Process.monitor(socket2.channel_pid)

    QPBX.Repo.update_all(from(x in Core.ApiKey, where: x.id == ^k2.id),
      set: [expires_at: ~U[2020-01-01 00:00:00Z]]
    )

    send(socket2.channel_pid, :recheck)
    assert_receive {:DOWN, ^ref, :process, _, _}
  end
end
