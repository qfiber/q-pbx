defmodule QPBX.EdgeTest do
  use QPBX.DataCase, async: false
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Edge.Registrations

  @actor {:system, "test"}

  setup do
    old = Application.get_env(:qpbx, QPBX.Edge)

    Application.put_env(:qpbx, QPBX.Edge,
      jsonrpc_url: "http://kamailio.test/RPC",
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn -> Application.put_env(:qpbx, QPBX.Edge, old || []) end)
    %{platform: Core.scope_for(platform_admin_fixture())}
  end

  # A fake Kamailio: answers uac.reg_dump with `dump`, records every call.
  defp kamailio(dump) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"method" => method, "params" => params} = Jason.decode!(body)
      send(test, {:rpc, method, params})

      Req.Test.json(conn, %{
        "jsonrpc" => "2.0",
        "result" => if(method == "uac.reg_dump", do: dump, else: "ok"),
        "id" => 1
      })
    end)
  end

  test "reload asks Kamailio to reload one htable; trunks also reload the dispatcher" do
    kamailio([])
    assert :ok = QPBX.Edge.reload("credentials")
    assert_received {:rpc, "htable.reload", ["credentials"]}
    assert :ok = QPBX.Edge.reload_trunks()
    assert_received {:rpc, "htable.reload", ["trunks"]}
    assert_received {:rpc, "dispatcher.reload", []}
  end

  test "an error answer is reported" do
    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, %{"jsonrpc" => "2.0", "error" => %{"code" => 500}, "id" => 1})
    )

    assert {:error, _} = QPBX.Edge.reload("domains")
  end

  test "registration trunks are pushed with their password; up-to-date ones are left alone; stale ones removed",
       %{platform: p} do
    {:ok, trunk} =
      Core.create_trunk(
        p,
        %{
          name: "R",
          auth_mode: "registration",
          username: "acct",
          password: "s3cret",
          addresses: [%{host: "sip.carrier.example", port: 5070, transport: "tcp"}]
        },
        @actor
      )

    {:ok, _ip} =
      Core.create_trunk(
        p,
        %{name: "I", auth_mode: "ip", addresses: [%{host: "192.0.2.9"}]},
        @actor
      )

    kamailio([%{"l_uuid" => "stale-trunk"}])
    assert :ok = Registrations.sync()

    assert_received {:rpc, "uac.reg_add",
                     [
                       id,
                       id,
                       _domain,
                       "acct",
                       "sip.carrier.example",
                       ".",
                       "acct",
                       "s3cret",
                       ".",
                       proxy,
                       300,
                       0,
                       0,
                       ".",
                       "."
                     ]}

    assert id == trunk.id
    assert proxy == "sip:sip.carrier.example:5070;transport=tcp"
    assert_received {:rpc, "uac.reg_remove", ["stale-trunk"]}
    refute_received {:rpc, "uac.reg_add", _}

    # Kamailio already has exactly this record: nothing to do.
    current = Registrations.record(Core.registration_trunks() |> hd())
    kamailio([current])
    assert :ok = Registrations.sync()
    refute_received {:rpc, "uac.reg_add", _}
    refute_received {:rpc, "uac.reg_remove", _}

    # A changed password is pushed again.
    kamailio([%{current | "auth_password" => "old"}])
    assert :ok = Registrations.sync()
    assert_received {:rpc, "uac.reg_add", _}
  end

  test "without a configured Kamailio nothing is sent" do
    Application.put_env(:qpbx, QPBX.Edge, [])
    assert :ok = QPBX.Edge.reload("domains")
    assert :ok = Registrations.sync()
  end
end
