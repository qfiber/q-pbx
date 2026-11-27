defmodule QPBX.Web.RealIPTest do
  use ExUnit.Case, async: true
  import Plug.Test
  alias QPBX.Web.RealIP

  defp from(peer, header) do
    conn = %{conn(:get, "/") | remote_ip: peer}
    conn = if header, do: Plug.Conn.put_req_header(conn, "x-real-ip", header), else: conn
    RealIP.call(conn, []).remote_ip
  end

  test "trusts X-Real-IP only from localhost (nginx)" do
    assert from({127, 0, 0, 1}, "203.0.113.9") == {203, 0, 113, 9}
    assert from({0, 0, 0, 0, 0, 0, 0, 1}, "2001:db8::7") == {8193, 3512, 0, 0, 0, 0, 0, 7}
    assert from({198, 51, 100, 1}, "203.0.113.9") == {198, 51, 100, 1}
  end

  test "ignores missing, malformed or repeated headers" do
    assert from({127, 0, 0, 1}, nil) == {127, 0, 0, 1}
    assert from({127, 0, 0, 1}, "not-an-ip") == {127, 0, 0, 1}
    assert from({127, 0, 0, 1}, "203.0.113.9, 10.0.0.1") == {127, 0, 0, 1}
  end
end
