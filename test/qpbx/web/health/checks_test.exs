defmodule QPBX.Web.Health.ChecksTest do
  use QPBX.DataCase, async: true
  alias QPBX.Web.Health
  alias QPBX.Web.Health.Checks

  test "postgres and oban backlog are ok against the test database" do
    assert {:ok, _} = Checks.postgres([])
    assert {:ok, "0 waiting"} = Checks.oban_backlog([])
    assert {:warning, _} = Checks.oban_backlog(warn: 0)
  end

  test "df output parsing and thresholds" do
    out = "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 1000 900 100 90% /\n"
    assert {:ok, 10} = Checks.parse_df(out)
    assert {:error, _} = Checks.parse_df("garbage")
    assert {:ok, _} = Checks.disk(paths: ["/"], warn_percent: 0, error_percent: 0)
    assert {:error, _} = Checks.disk(paths: ["/"], warn_percent: 101, error_percent: 101)
    assert {:error, _} = Checks.disk(paths: ["/does/not/exist"])
  end

  test "certificate expiry from a real PEM" do
    dir = Path.join(System.tmp_dir!(), "qpbx-cert-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    pem = fn days ->
      path = Path.join(dir, "c#{days}.pem")
      key = X509Helper.self_signed(days)
      File.write!(path, key)
      path
    end

    assert {:ok, "expires in " <> _} = Checks.certificate(path: pem.(60))
    assert {:warning, _} = Checks.certificate(path: pem.(5))
    assert {:error, "cannot read" <> _} = Checks.certificate(path: Path.join(dir, "missing.pem"))
    assert {:not_configured, _} = Checks.certificate([])
  end

  test "freeswitch and kamailio report errors when nothing listens, not_configured when unset" do
    assert {:not_configured, _} = Checks.freeswitch([])
    assert {:not_configured, _} = Checks.kamailio([])
    # Port 1 on localhost: nothing listens there.
    assert {:error, _} = Checks.freeswitch(event_socket: {"127.0.0.1", 1})
    assert {:error, _} = Checks.kamailio(jsonrpc_url: "http://127.0.0.1:1/RPC")
  end

  test "freeswitch is ok when the event socket accepts connections" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    assert {:ok, _} = Checks.freeswitch(event_socket: {"127.0.0.1", port})
    :gen_tcp.close(listen)
  end

  test "overall status rules" do
    ok = %{status: :ok, detail: ""}
    assert Health.overall(%{postgres: ok, disk: ok}) == "ok"
    assert Health.overall(%{postgres: ok, disk: %{ok | status: :warning}}) == "degraded"
    assert Health.overall(%{postgres: ok, disk: %{ok | status: :error}}) == "degraded"
    assert Health.overall(%{postgres: %{ok | status: :error}, disk: ok}) == "down"
    assert Health.overall(%{postgres: ok, freeswitch: %{ok | status: :not_configured}}) == "ok"
  end

  test "a hanging check is reported as timed out" do
    # Kamailio URL on a port that accepts but never answers.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    result = Health.run(kamailio: [jsonrpc_url: "http://127.0.0.1:#{port}/RPC"])
    assert result.components.kamailio.status == :error
    assert result.status == "down"
    :gen_tcp.close(listen)
  end
end
