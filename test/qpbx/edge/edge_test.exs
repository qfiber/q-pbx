defmodule QPBX.EdgeTest do
  use ExUnit.Case, async: false

  setup do
    old = Application.get_env(:qpbx, QPBX.Edge)

    Application.put_env(:qpbx, QPBX.Edge,
      jsonrpc_url: "http://kamailio.test/RPC",
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn -> Application.put_env(:qpbx, QPBX.Edge, old || []) end)
  end

  test "reload asks Kamailio over JSON-RPC to reload one htable" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"method" => "htable.reload", "params" => ["credentials"]} = Jason.decode!(body)
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => "ok", "id" => 1})
    end)

    assert :ok = QPBX.Edge.reload("credentials")
  end

  test "an error answer is reported" do
    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, %{"jsonrpc" => "2.0", "error" => %{"code" => 500}, "id" => 1})
    )

    assert {:error, _} = QPBX.Edge.reload("domains")
  end

  test "without a configured Kamailio nothing is sent" do
    Application.put_env(:qpbx, QPBX.Edge, [])
    assert :ok = QPBX.Edge.reload("domains")
  end
end
