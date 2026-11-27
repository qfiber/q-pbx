defmodule QPBX.Web.FreeswitchControllerTest do
  use QPBX.Web.ConnCase, async: false

  @password "curl-password-0123456789"

  setup do
    old = Application.get_env(:qpbx, QPBX.Telephony)
    Application.put_env(:qpbx, QPBX.Telephony, curl_password: @password)
    on_exit(fn -> Application.put_env(:qpbx, QPBX.Telephony, old || []) end)
  end

  defp auth(conn, pw),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("freeswitch:" <> pw))

  test "FreeSWITCH on this server gets the park dialplan", %{conn: conn} do
    body =
      conn
      |> auth(@password)
      |> post(~p"/internal/freeswitch/dialplan", %{"section" => "dialplan"})
      |> response(200)

    assert body =~ ~s(<action application="set" data="qpbx_call=true"/>)
    assert body =~ ~s(park_timeout=30:NORMAL_TEMPORARY_FAILURE)
    assert body =~ ~s(<action application="park"/>)
    assert body =~ ~s(continue_on_fail=true)
  end

  test "refused without the password, with a wrong one, or through nginx", %{conn: conn} do
    assert conn |> post(~p"/internal/freeswitch/dialplan") |> response(403)

    assert build_conn()
           |> auth("wrong-password-0123456789")
           |> post(~p"/internal/freeswitch/dialplan")
           |> response(403)

    # Through nginx the request carries X-Real-IP: the client's address, not loopback.
    assert build_conn()
           |> auth(@password)
           |> put_req_header("x-real-ip", "203.0.113.5")
           |> post(~p"/internal/freeswitch/dialplan")
           |> response(403)
  end
end
