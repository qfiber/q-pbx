defmodule QPBX.Web.SettingsLiveTest do
  @moduledoc "Platform settings: outgoing email and the sign-in check, in the portal and the API."
  use QPBX.Web.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Notify.Mail
  alias QPBX.Web.Captcha

  defp signed_in(conn, account) do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, ~p"/platform/login", login: %{email: account.email, password: password()})
    conn = post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)})
    {recycle(conn), account}
  end

  setup %{conn: conn} do
    {conn, admin} = signed_in(conn, platform_admin_fixture())
    %{conn: conn, admin: admin}
  end

  test "email: saved settings apply to the next email; the password is kept and never shown; reset",
       %{conn: conn, admin: admin} do
    {:ok, view, html} = live(conn, ~p"/platform/settings")
    assert html =~ "Outgoing email"

    view
    |> form("#email-form",
      email: %{
        smtp_host: "mail.example.com",
        smtp_port: "2525",
        smtp_username: "relay",
        smtp_password: "s3cret",
        mail_from: "pbx@example.com"
      }
    )
    |> render_submit()

    s = Core.platform_settings()
    assert %{smtp_host: "mail.example.com", smtp_port: 2525, smtp_password: "s3cret"} = s

    assert Mail.smtp(s) ==
             [relay: "mail.example.com", port: 2525, auth: :always, tls: :always] ++
               [username: "relay", password: "s3cret"]

    assert Mail.sender() == {"Q-PBX", "pbx@example.com"}
    refute render(view) =~ "s3cret"

    # An empty password keeps the saved one.
    view |> form("#email-form", email: %{smtp_port: "587", smtp_password: ""}) |> render_submit()
    assert %{smtp_port: 587, smtp_password: "s3cret"} = Core.platform_settings()

    [entry | _] = Core.list_audit_logs(limit: 1)
    assert entry.action == "platform_settings.update"
    refute Map.has_key?(entry.changes, "smtp_password")

    # A server without a login: none is sent (Swoosh needs strings, not nil).
    {:ok, s} = Core.update_platform_settings(%{smtp_username: nil}, admin)

    assert Mail.smtp(s) == [
             relay: "mail.example.com",
             port: 587,
             auth: :never,
             tls: :if_available,
             username: "",
             password: ""
           ]

    view |> element("#reset-email") |> render_click()
    s = Core.platform_settings()
    assert is_nil(s.smtp_host) and is_nil(s.smtp_password) and Mail.smtp(s) == []

    html = view |> form("#email-form", email: %{smtp_port: "99999"}) |> render_submit()
    assert html =~ "must be less than"
    _ = admin
  end

  test "a test email goes out now with the current settings", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/platform/settings")
    view |> form("#test-email-form", test: %{to: "ops@example.com"}) |> render_submit()
    assert has_element?(view, "#test-email-ok")
    assert_email_sent(fn e -> e.to == [{"", "ops@example.com"}] and e.subject =~ "test email" end)
  end

  test "sign-in check: the saved provider wins; an outside service needs its keys", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/platform/settings")

    html =
      view
      |> form("#captcha-form", captcha: %{captcha_provider: "turnstile"})
      |> render_submit()

    assert html =~ "can&#39;t be blank"

    view
    |> form("#captcha-form",
      captcha: %{captcha_provider: "turnstile", captcha_site_key: "site", captcha_secret: "sec"}
    )
    |> render_submit()

    assert Captcha.provider() == :turnstile
    assert Captcha.config()[:secret] == "sec"

    # Proof of work: its strength is chosen here and reaches the challenge.
    view |> form("#captcha-form", captcha: %{captcha_provider: "pow"}) |> render_change()
    assert has_element?(view, "#pow-strength")

    view
    |> form("#captcha-form", captcha: %{captcha_provider: "pow", pow_max_number: "200000"})
    |> render_submit()

    assert Captcha.Pow.challenge().maxnumber == 200_000

    view |> form("#captcha-form", captcha: %{captcha_provider: "turnstile"}) |> render_change()
    refute has_element?(view, "#pow-strength")

    view |> element("#reset-captcha") |> render_click()
    assert Captcha.provider() == (Application.get_env(:qpbx, Captcha, [])[:provider] || :pow)
    assert Captcha.Pow.challenge().maxnumber == 60_000
  end

  test "the API reads and changes the settings, never returning secrets; a test email", %{
    conn: conn,
    admin: admin
  } do
    {:ok, _, key} =
      Core.create_api_key(Core.scope_for(admin), %{name: "s", scopes: ["read", "admin"]}, admin)

    api = fn c -> c |> recycle() |> put_req_header("authorization", "Bearer " <> key) end

    resp =
      conn
      |> api.()
      |> patch(~p"/v1/platform-settings", %{smtp_host: "relay.example.com", smtp_password: "pw"})
      |> json_response(200)

    assert resp["data"]["smtp_host"] == "relay.example.com"
    refute Map.has_key?(resp["data"], "smtp_password")

    body = conn |> api.() |> get(~p"/v1/platform-settings") |> json_response(200)
    refute inspect(body) =~ "pw\""

    assert conn
           |> api.()
           |> post(~p"/v1/platform-settings/test-email", %{to: "x@example.com"})
           |> response(204)
  end
end
