defmodule QPBX.Web.VoicemailPagesTest do
  use QPBX.Web.ConnCase, async: false
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.{Core, Telephony}
  alias QPBX.Telephony.Voicemail

  @actor {:system, "test"}
  @mp3 <<"ID3", 4, 0, 0, 0, 0, 0, 0>> <> :binary.copy(<<7>>, 100)

  defp signed_in(conn, account) do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, ~p"/login", login: %{email: account.email, password: password()})
    conn = post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)})
    recycle(conn)
  end

  setup %{conn: conn} do
    t = tenant_fixture()
    admin = user_fixture(t, "tenant_admin")
    scope = Core.scope_for(admin)
    {:ok, ext} = Core.create_extension(scope, %{number: "101", name: "A"}, @actor)
    %{conn: conn, t: t, admin: admin, scope: scope, ext: ext}
  end

  test "set up a mailbox, upload a greeting", %{conn: conn, admin: admin, scope: scope, ext: ext} do
    conn = signed_in(conn, admin)
    {:ok, view, html} = live(conn, ~p"/app/extensions/#{ext.id}/voicemail")
    refute html =~ "greeting-form"

    html = view |> form("#mailbox-form", mailbox: %{pin: "1111"}) |> render_submit()
    assert html =~ "too easy to guess"
    view |> form("#mailbox-form", mailbox: %{pin: "4831", email: "a@x.test"}) |> render_submit()
    assert %{email: "a@x.test"} = Telephony.mailbox(scope, ext.id)

    # Saving with an empty PIN keeps the old one.
    {:ok, view, _} = live(conn, ~p"/app/extensions/#{ext.id}/voicemail")
    view |> form("#mailbox-form", mailbox: %{pin: "", email: "b@x.test"}) |> render_submit()
    mb = Telephony.mailbox(scope, ext.id)
    assert mb.email == "b@x.test" and Voicemail.pin_ok?(mb, "4831")

    upload =
      file_input(view, "#greeting-form", :greeting, [
        %{name: "hello.mp3", content: @mp3, type: "audio/mpeg"}
      ])

    render_upload(upload, "hello.mp3")
    html = view |> form("#greeting-form", greeting: %{kind: "busy"}) |> render_submit()
    assert html =~ "Greeting saved."
    assert Telephony.greetings(scope, ext.id) == ["busy"]

    upload =
      file_input(view, "#greeting-form", :greeting, [
        %{name: "x.mp3", content: "<html>not audio", type: "audio/mpeg"}
      ])

    render_upload(upload, "x.mp3")

    assert view |> form("#greeting-form", greeting: %{kind: "temporary"}) |> render_submit() =~
             "not MP3 or WAV"
  end

  test "messages: listed, played (marks heard), deleted; audio only for the tenant's admins",
       %{conn: conn, t: t, admin: admin, scope: scope, ext: ext} do
    {:ok, _} = Telephony.save_mailbox(scope, ext.id, %{pin: "4831"}, admin)

    {:ok, v} =
      Voicemail.store_system(Voicemail.mailbox_system(t.id, ext.id), @mp3, %{
        duration: 9,
        format: "mp3",
        caller_number: "0501234567"
      })

    admin_conn = signed_in(conn, admin)
    {:ok, view, html} = live(admin_conn, ~p"/app/voicemail")
    assert html =~ "0501234567" and html =~ "New"

    resp = get(admin_conn, ~p"/app/voicemail/#{v.id}/audio")
    assert resp.status == 200 and resp.resp_body == @mp3
    assert get_resp_header(resp, "content-type") == ["audio/mpeg"]
    assert get_resp_header(resp, "cache-control") == ["private, no-store"]

    render_hook(view, "save", %{"id" => v.id})
    assert render(view) =~ "Heard"
    view |> element("#delete-#{v.id}") |> render_click()
    assert render(view) =~ "No messages."

    {:ok, v2} =
      Voicemail.store_system(Voicemail.mailbox_system(t.id, ext.id), @mp3, %{
        duration: 2,
        format: "mp3"
      })

    other = user_fixture(tenant_fixture(), "tenant_admin")
    assert get(signed_in(build_conn(), other), ~p"/app/voicemail/#{v2.id}/audio").status == 404
    plain_user = user_fixture(t, "tenant_user")

    assert get(signed_in(build_conn(), plain_user), ~p"/app/voicemail/#{v2.id}/audio").status ==
             404

    assert redirected_to(get(build_conn(), ~p"/app/voicemail/#{v2.id}/audio")) == ~p"/login"
  end

  test "deleting the extension removes its messages and greetings, files included",
       %{conn: conn, t: t, admin: admin, scope: scope, ext: ext} do
    {:ok, _} = Telephony.save_mailbox(scope, ext.id, %{pin: "4831"}, admin)
    :ok = Telephony.put_greeting(scope, ext.id, "busy", @mp3, admin)

    {:ok, v} =
      Voicemail.store_system(Voicemail.mailbox_system(t.id, ext.id), @mp3, %{
        duration: 2,
        format: "mp3"
      })

    {:ok, view, _} = live(signed_in(conn, admin), ~p"/app/extensions/#{ext.id}")
    view |> element("#delete-extension") |> render_click()
    assert {:error, :enoent} = QPBX.Storage.get(v.file_key)
    assert Telephony.list_voicemails(scope) == []
    assert QPBX.Repo.aggregate(QPBX.Telephony.Voicemail.Greeting, :count) == 0
  end
end
