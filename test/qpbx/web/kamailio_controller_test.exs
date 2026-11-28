defmodule QPBX.Web.KamailioControllerTest do
  use QPBX.Web.ConnCase, async: false
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Events.ExtensionRegistration

  @secret "kamailio-secret-0123456789"

  setup do
    old = Application.get_env(:qpbx, QPBX.Edge)
    Application.put_env(:qpbx, QPBX.Edge, Keyword.put(old || [], :event_secret, @secret))
    on_exit(fn -> Application.put_env(:qpbx, QPBX.Edge, old) end)

    t = tenant_fixture()

    {:ok, ext} =
      Core.create_extension(
        Core.scope_for(user_fixture(t)),
        %{number: "101", name: "A"},
        {:system, "t"}
      )

    QPBX.Events.subscribe(ExtensionRegistration)
    %{t: t, ext: ext}
  end

  defp report(conn, body, secret \\ @secret) do
    conn
    |> put_req_header("x-qpbx-secret", secret)
    |> put_req_header("content-type", "application/json")
    |> post("/internal/kamailio/registration", Jason.encode!(body))
  end

  test "a registration, an unregistration and an expiry become events", %{
    conn: conn,
    t: t,
    ext: ext
  } do
    aor = "101-desk@#{t.sip_domain}"

    assert report(conn, %{
             event: "registered",
             aor: aor,
             contact: "203.0.113.5:5062",
             ua_hex: Base.encode16("Meow 1.0")
           }).status == 204

    assert_receive {:event,
                    %ExtensionRegistration{
                      type: "registered",
                      device: "101-desk",
                      extension: "101",
                      contact: "203.0.113.5:5062",
                      user_agent: "Meow 1.0"
                    } = e}

    assert e.tenant_id == t.id and e.extension_id == ext.id

    assert report(conn, %{event: "unregistered", aor: aor}).status == 204
    assert_receive {:event, %ExtensionRegistration{type: "unregistered", reason: "unregister"}}

    # A login without a label is the extension number itself.
    assert report(conn, %{event: "expired", aor: "101@#{t.sip_domain}"}).status == 204

    assert_receive {:event,
                    %ExtensionRegistration{type: "unregistered", reason: "expired", device: "101"}}
  end

  test "unknown extensions and bad reports are refused without an event", %{conn: conn, t: t} do
    assert report(conn, %{event: "registered", aor: "999@#{t.sip_domain}"}).status == 422
    assert report(conn, %{event: "registered", aor: "101@other.example"}).status == 422
    assert report(conn, %{event: "rebooted", aor: "101@#{t.sip_domain}"}).status == 422
    refute_receive {:event, %ExtensionRegistration{}}, 50
  end

  test "only from this server and with the secret", %{conn: conn, t: t} do
    body = %{event: "registered", aor: "101@#{t.sip_domain}"}
    assert report(conn, body, "wrong-secret-0123456789").status == 403
    assert report(%{conn | remote_ip: {198, 51, 100, 1}}, body).status == 403
    Application.put_env(:qpbx, QPBX.Edge, event_secret: nil)
    assert report(conn, body).status == 403
    refute_receive {:event, %ExtensionRegistration{}}, 50
  end
end
