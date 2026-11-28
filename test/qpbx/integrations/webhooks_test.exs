defmodule QPBX.Integrations.WebhooksTest do
  use QPBX.DataCase, async: false
  use Oban.Testing, repo: QPBX.Repo
  import QPBX.Fixtures
  alias QPBX.{Core, Integrations}
  alias QPBX.Events.{CallEvent, WebhookDeadLettered}
  alias QPBX.Integrations.Webhooks
  alias QPBX.Integrations.Webhooks.{Delivery, Signature, Worker}

  @actor {:system, "test"}

  defmodule Receiver do
    @moduledoc false
    # Answers with the status the test set (default 200) and reports each request to the test.
    use Plug.Router
    plug :match
    plug :dispatch

    match _ do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [{:test, pid, status}] = :ets.lookup(:qpbx_webhook_receiver, :test)
      send(pid, {:received, Map.new(conn.req_headers), body})
      send_resp(conn, status, "thanks")
    end
  end

  setup do
    k = [key: {:namedCurve, :secp256r1}, digest: :sha256]
    san = {:Extension, {2, 5, 29, 17}, false, [iPAddress: <<127, 0, 0, 1>>]}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: k, intermediates: [], peer: k ++ [extensions: [san]]},
        client_chain: %{root: k, intermediates: [], peer: k}
      })

    {:ok, pid} =
      start_supervised(
        {Bandit,
         plug: Receiver,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [transport_options: data.server_config]}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    if :ets.whereis(:qpbx_webhook_receiver) == :undefined,
      do: :ets.new(:qpbx_webhook_receiver, [:named_table, :public])

    :ets.insert(:qpbx_webhook_receiver, {:test, self(), 200})

    # The installation trusts the test receiver: its address and its CA, as the lab does.
    ca = Path.join(System.tmp_dir!(), "qpbx-webhook-ca-#{System.unique_integer([:positive])}.pem")

    File.write!(
      ca,
      :public_key.pem_encode(
        for der <- data.client_config[:cacerts], do: {:Certificate, der, :not_encrypted}
      )
    )

    old = Application.get_env(:qpbx, QPBX.Integrations)
    Application.put_env(:qpbx, QPBX.Integrations, allow_cidrs: ["127.0.0.1"], ca_file: ca)

    on_exit(fn ->
      Application.put_env(:qpbx, QPBX.Integrations, old || [])
      File.rm(ca)
    end)

    t = tenant_fixture()
    scope = Core.scope_for(user_fixture(t))
    %{t: t, scope: scope, url: "https://127.0.0.1:#{port}/hook"}
  end

  defp answer(status), do: :ets.insert(:qpbx_webhook_receiver, {:test, self(), status})

  defp call_event(tid, type \\ "started"),
    do: %CallEvent{
      type: type,
      tenant_id: tid,
      call_id: "c1",
      direction: "internal",
      from: "101",
      to: "102",
      at: ~U[2026-11-28 10:00:00Z]
    }

  defp endpoint(scope, url, types \\ ["call.started"]) do
    {:ok, e, secret} = Integrations.create_webhook(scope, %{url: url, event_types: types}, @actor)
    {e, secret}
  end

  defp run_pending do
    for job <- all_enqueued(worker: Worker),
        do: perform_job(Worker, job.args, attempt: job.attempt + 1)
  end

  test "signature: a known test vector, and the receiver's check" do
    body = ~s({"id":"e1","type":"call.started"})
    expected = "v1=1e8cd6ccf365a48577ed0780c189fb80ee40d24ca7e691463d09572dd8efcbd0"
    assert Signature.sign("whsec_test-vector-secret", 1_700_000_000, body) == expected

    assert Signature.valid?(
             "whsec_test-vector-secret",
             expected,
             "1700000000",
             body,
             1_700_000_100
           )

    refute Signature.valid?(
             "whsec_test-vector-secret",
             expected,
             "1700000000",
             body <> " ",
             1_700_000_100
           )

    refute Signature.valid?("whsec_other", expected, "1700000000", body, 1_700_000_100)
    # Too old: a captured request replayed later.
    refute Signature.valid?(
             "whsec_test-vector-secret",
             expected,
             "1700000000",
             body,
             1_700_001_000
           )
  end

  test "endpoints: HTTPS only, no internal addresses, a secret shown once and stored encrypted",
       %{scope: scope, url: url} do
    assert {:error, cs} =
             Integrations.create_webhook(
               scope,
               %{url: "http://example.com/x", event_types: ["call.started"]},
               @actor
             )

    assert %{url: ["must start with https://"]} = errors_on(cs)

    assert {:error, cs} =
             Integrations.create_webhook(
               scope,
               %{url: "https://10.1.2.3/x", event_types: ["call.started"]},
               @actor
             )

    assert %{url: ["points to an internal address"]} = errors_on(cs)
    assert {:error, cs} = Integrations.create_webhook(scope, %{url: url, event_types: []}, @actor)
    assert %{event_types: ["pick at least one event"]} = errors_on(cs)

    assert {:error, cs} =
             Integrations.create_webhook(scope, %{url: url, event_types: ["fax.sent"]}, @actor)

    assert %{event_types: [_]} = errors_on(cs)

    {e, secret} = endpoint(scope, url)
    assert "whsec_" <> _ = secret

    {:ok, %{rows: [[raw]]}} =
      Repo.query("SELECT secret FROM webhook_endpoints WHERE id = $1", [Ecto.UUID.dump!(e.id)])

    refute raw =~ secret

    # Moving it to an internal address later is refused too.
    assert {:error, cs} =
             Integrations.update_webhook(scope, e, %{url: "https://169.254.169.254/"}, @actor)

    assert %{url: ["points to an internal address"]} = errors_on(cs)

    {:ok, _, new} = Integrations.rotate_webhook_secret(scope, e, @actor)
    assert new != secret

    # Another tenant sees nothing of it.
    other = Core.scope_for(user_fixture(tenant_fixture()))
    assert Integrations.get_webhook(other, e.id) == nil
    assert Integrations.list_webhooks(other) == []
  end

  test "an event becomes a signed delivery to the endpoints that want it, sent at once", %{
    t: t,
    scope: scope,
    url: url
  } do
    {e, secret} = endpoint(scope, url, ["call.started", "call.ended"])
    {_, _} = endpoint(scope, url, ["call.ended"])

    {:ok, _off, _} =
      Integrations.create_webhook(
        scope,
        %{url: url, event_types: ["call.started"], enabled: false},
        @actor
      )

    other = Core.scope_for(user_fixture(tenant_fixture()))
    {_, _} = endpoint(other, url)

    :ok = Webhooks.dispatch(call_event(t.id))
    assert [job] = all_enqueued(worker: Worker)
    assert [:ok] = run_pending()

    assert_receive {:received, headers, body}

    assert Signature.valid?(
             secret,
             headers["x-qpbx-signature"],
             headers["x-qpbx-timestamp"],
             body
           )

    assert headers["x-qpbx-event-type"] == "call.started"

    assert %{
             "id" => id,
             "type" => "call.started",
             "version" => 1,
             "tenant_id" => tid,
             "data" => %{"call_id" => "c1", "from" => "101", "direction" => "internal"}
           } =
             Jason.decode!(body)

    assert tid == t.id and headers["x-qpbx-event-id"] == id
    [d] = Integrations.list_webhook_deliveries(scope, e)
    assert %{status: "delivered", attempts: [%{"status" => 200, "response" => "thanks"}]} = d
    assert d.delivered_at
    _ = job
  end

  test "failures are retried with growing pauses; after 24 hours the delivery is dead", %{
    t: t,
    scope: scope,
    url: url
  } do
    {e, _} = endpoint(scope, url)
    answer(500)
    QPBX.Events.subscribe(WebhookDeadLettered)
    :ok = Webhooks.dispatch(call_event(t.id))
    [job] = all_enqueued(worker: Worker)

    assert {:error, "HTTP 500"} = perform_job(Worker, job.args, attempt: 1)

    assert [%{status: "pending", attempts: [%{"status" => 500}]}] =
             Integrations.list_webhook_deliveries(scope, e)

    assert Enum.map(1..12, &Worker.pause/1) == [
             30,
             60,
             120,
             240,
             480,
             960,
             1920,
             3840,
             7680,
             15_360,
             21_600,
             21_600
           ]

    # The 24 hours run out before Oban's attempt limit (20) does.
    assert Enum.sum(Enum.map(1..14, &Worker.pause/1)) > 24 * 3600

    # A day later: given up, and the alert source hears of it.
    [d] = Integrations.list_webhook_deliveries(scope, e)

    Repo.update_all(from(x in Delivery, where: x.id == ^d.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -24 * 3600)]
    )

    assert {:cancel, :dead} = perform_job(Worker, job.args, attempt: 13)
    assert [%{status: "dead", attempts: [_, _]}] = Integrations.list_webhook_deliveries(scope, e)
    assert_receive {:event, %WebhookDeadLettered{endpoint_id: eid}}
    assert eid == e.id

    # Resent: a new delivery of the same event, which now arrives.
    answer(200)

    {:ok, again} =
      Integrations.resend_webhook_delivery(
        scope,
        Integrations.get_webhook_delivery(scope, d.id),
        @actor
      )

    assert again.event_id == d.event_id and again.id != d.id
    job = Enum.find(all_enqueued(worker: Worker), &(&1.args["delivery_id"] == again.id))
    assert :ok = perform_job(Worker, job.args, attempt: 1)
    assert_receive {:received, %{"x-qpbx-event-id" => event_id}, _}
    assert event_id == d.event_id
  end

  test "an endpoint that stops resolving to a public address is refused at delivery and logged",
       %{t: t, scope: scope, url: url} do
    {e, _} = endpoint(scope, url)
    :ok = Webhooks.dispatch(call_event(t.id))

    # The operator no longer trusts the address: the next attempt is refused before any connection.
    Application.put_env(:qpbx, QPBX.Integrations, allow_cidrs: [])
    [job] = all_enqueued(worker: Worker)

    assert {:error, "refused: 127.0.0.1 is an internal address"} =
             perform_job(Worker, job.args, attempt: 1)

    refute_receive {:received, _, _}, 100

    assert [%{attempts: [%{"error" => "refused: 127.0.0.1 is an internal address"}]}] =
             Integrations.list_webhook_deliveries(scope, e)
  end

  test "deliveries page by cursor; old ones are pruned", %{t: t, scope: scope, url: url} do
    {e, _} = endpoint(scope, url)
    for _ <- 1..3, do: :ok = Webhooks.dispatch(call_event(t.id))
    [a, b] = Integrations.list_webhook_deliveries(scope, e, 2)
    assert [c] = Integrations.list_webhook_deliveries(scope, e, 2, {b.inserted_at, b.id})
    assert Enum.uniq([a.id, b.id, c.id]) |> length() == 3

    Repo.update_all(from(x in Delivery, where: x.id == ^c.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -31, :day)]
    )

    assert {:ok, 1} = Webhooks.prune(30)
  end
end
