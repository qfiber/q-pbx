defmodule QPBX.Edge.BansTest do
  use QPBX.DataCase, async: false
  alias QPBX.Edge.Bans
  alias QPBX.Events.EdgeAlert

  setup do
    QPBX.FakeHelper.reset()
    old = Application.get_env(:qpbx, QPBX.Edge)

    Application.put_env(:qpbx, QPBX.Edge,
      jsonrpc_url: "http://kamailio.test/RPC",
      req_options: [plug: {Req.Test, __MODULE__}],
      ban_seconds: 3600
    )

    on_exit(fn -> Application.put_env(:qpbx, QPBX.Edge, old || []) end)
  end

  # A fake Kamailio holding the given htable contents.
  defp kamailio(tables) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"params" => [name]} = Jason.decode!(body)

      items =
        for {k, v} <- Map.get(tables, name, []), do: %{"name" => k, "value" => v, "type" => "str"}

      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "result" => [%{"entry" => 1, "size" => length(items), "slot" => items}],
        "id" => 1
      })
    end)
  end

  defp blocks,
    do: QPBX.Firewall.list_entries(level: "platform") |> Enum.filter(&(&1.kind == "block"))

  test "whole-address bans go to the firewall once; address-and-port bans stay in Kamailio" do
    kamailio(%{"ipban" => [{"203.0.113.40", "scanner"}, {"203.0.113.41|5062", "auth failures"}]})
    state = Bans.poll(%{pushed: MapSet.new(), alerted: MapSet.new()})
    assert [%{cidr: "203.0.113.40", reason: "auto: scanner"}] = blocks()

    # Next round: nothing new to write.
    QPBX.Repo.delete_all(QPBX.Firewall.Entry)
    state = Bans.poll(state)
    assert blocks() == []

    # Gone from Kamailio, then banned again: pushed again.
    kamailio(%{})
    state = Bans.poll(state)
    kamailio(%{"ipban" => [{"203.0.113.40", "flood"}]})
    _ = Bans.poll(state)
    assert [%{reason: "auto: flood"}] = blocks()
    _ = QPBX.Firewall.sync_status()
  end

  test "bans of allowed addresses are lifted in Kamailio and never reach the firewall" do
    actor = {:system, "test"}
    tenant = QPBX.Fixtures.tenant_fixture()

    {:ok, _} =
      QPBX.Firewall.create_entry(
        %{
          level: "platform",
          kind: "allow",
          scope: "sip",
          cidr: "198.51.100.0/24",
          reason: "carrier"
        },
        actor
      )

    {:ok, _} =
      QPBX.Firewall.create_entry(
        %{
          level: "tenant",
          tenant_id: tenant.id,
          kind: "allow",
          scope: "sip",
          cidr: "192.0.2.0/28",
          reason: "HQ"
        },
        actor
      )

    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"method" => method, "params" => params} = Jason.decode!(body)
      send(test, {:rpc, method, params})

      items =
        if params == ["ipban"],
          do:
            for(
              k <- ["198.51.100.7", "192.0.2.3", "192.0.2.3|5060", "203.0.113.60"],
              do: %{"name" => k, "value" => "flood"}
            ),
          else: []

      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => [%{"slot" => items}], "id" => 1})
    end)

    _ = Bans.poll(%{pushed: MapSet.new(), alerted: MapSet.new()})
    assert_received {:rpc, "htable.delete", ["ipban", "198.51.100.7"]}
    assert_received {:rpc, "htable.delete", ["ipban", "192.0.2.3"]}
    refute_received {:rpc, "htable.delete", ["ipban", "192.0.2.3|5060"]}
    assert [%{cidr: "203.0.113.60"}] = blocks()
    _ = QPBX.Firewall.sync_status()
  end

  test "an office IP alert is announced once and audited" do
    QPBX.Events.subscribe(EdgeAlert)
    kamailio(%{"edgealert" => [{"192.0.2.9", "auth failures"}]})
    state = Bans.poll(%{pushed: MapSet.new(), alerted: MapSet.new()})
    assert_receive {:event, %EdgeAlert{ip: "192.0.2.9", reason: "auth failures"}}
    _ = Bans.poll(state)
    refute_receive {:event, %EdgeAlert{}}, 50
    assert Enum.any?(QPBX.Core.list_audit_logs(), &(&1.action == "edge.office_ip_alert"))
  end

  test "Kamailio unreachable: state kept, nothing written" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
    state = %{pushed: MapSet.new(["1.2.3.4"]), alerted: MapSet.new()}
    assert Bans.poll(state) == state
  end
end
