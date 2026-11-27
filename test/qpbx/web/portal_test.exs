defmodule QPBX.Web.PortalTest do
  @moduledoc "Phase 1 Done-when flow through the portal, in English and Arabic."
  use QPBX.Web.ConnCase, async: true
  use Oban.Testing, repo: QPBX.Repo
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.Core

  defp enable_totp(account) do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    # Move the last-used mark back so the current window's code is accepted in the test.
    account =
      QPBX.Repo.update!(
        Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z])
      )

    {account, secret}
  end

  defp log_in_platform(conn) do
    {admin, secret} = enable_totp(platform_admin_fixture())
    conn = post(conn, ~p"/platform/login", login: %{email: admin.email, password: password()})
    assert redirected_to(conn) == ~p"/2fa"
    conn = post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)})
    assert redirected_to(conn) == ~p"/platform"
    {recycle(conn), admin}
  end

  describe "platform admin" do
    test "logs in with password and TOTP", %{conn: conn} do
      {conn, _} = log_in_platform(conn)
      assert html_response(get(conn, ~p"/platform"), 200) =~ "Tenants"
    end

    test "without 2FA must enrol and cannot skip", %{conn: conn} do
      admin = platform_admin_fixture()
      conn = post(conn, ~p"/platform/login", login: %{email: admin.email, password: password()})
      assert redirected_to(conn) == ~p"/2fa/setup"
      conn = post(recycle(conn), ~p"/2fa/skip")
      assert redirected_to(conn) == ~p"/2fa/setup"
      assert get(recycle(conn), ~p"/platform") |> redirected_to() == ~p"/platform/login"
    end

    test "wrong password or wrong code gives no session", %{conn: conn} do
      {admin, _secret} = enable_totp(platform_admin_fixture())

      conn1 =
        post(conn, ~p"/platform/login", login: %{email: admin.email, password: "nope nope nope"})

      assert html_response(conn1, 200) =~ "Wrong email or password"

      conn2 = post(conn, ~p"/platform/login", login: %{email: admin.email, password: password()})
      conn2 = post(recycle(conn2), ~p"/2fa", totp: %{code: "000000"})
      assert html_response(conn2, 200) =~ "not valid"
      assert get(recycle(conn2), ~p"/platform") |> redirected_to() == ~p"/platform/login"
    end

    test "a tenant user cannot reach platform pages", %{conn: conn} do
      user = user_fixture()
      conn = post(conn, ~p"/login", login: %{email: user.email, password: password()})
      assert redirected_to(conn) == ~p"/app"
      assert get(recycle(conn), ~p"/platform") |> redirected_to() == ~p"/platform/login"
    end
  end

  describe "Done when: platform admin creates a tenant, tenant admin logs in with 2FA" do
    for locale <- ["en", "ar"] do
      @tag locale: locale
      test "in #{locale}", %{conn: conn, locale: locale} do
        {conn, _admin} = log_in_platform(conn)

        # Create a plan.
        {:ok, view, _} = live(conn, ~p"/platform/plans")

        view
        |> form("#plan-form", plan: %{name: "Basic #{locale}", max_extensions: "20"})
        |> render_submit()

        plan = Enum.find(Core.list_plans(), &(&1.name == "Basic #{locale}"))
        assert plan.max_extensions == 20

        # Create the tenant with its first admin.
        {:ok, view, _} = live(conn, ~p"/platform/tenants/new")
        email = "boss-#{locale}@acme.test"

        html =
          view
          |> form("#tenant-form",
            tenant: %{
              name: "Acme #{locale}",
              slug: "acme-#{locale}",
              plan_id: plan.id,
              timezone: "Asia/Jerusalem",
              locale: locale,
              admin_name: "Boss",
              admin_email: email
            }
          )
          |> render_submit()

        assert html =~ "/setup/"
        tenant = Enum.find(Core.list_tenants(), &(&1.slug == "acme-#{locale}"))
        assert tenant.plan_id == plan.id

        assert_enqueued(
          worker: QPBX.Notify.SetupLinkEmail,
          args: %{"email" => email, "locale" => locale}
        )

        assert Enum.any?(
                 Core.list_audit_logs(),
                 &(&1.action == "tenant.create" and &1.target_id == tenant.id)
               )

        # The tenant admin opens the setup link, sets a password and turns on 2FA.
        [url] = Regex.run(~r{http[^\s<"]+/setup/[^\s<"]+}, html)
        path = URI.parse(url).path
        conn = build_conn()
        assert html_response(get(conn, path), 200) =~ email

        conn =
          put(conn, path, account: %{password: password(), password_confirmation: password()})

        assert redirected_to(conn) == ~p"/2fa/setup"

        conn = get(recycle(conn), ~p"/2fa/setup")
        page = html_response(conn, 200)
        [secret32] = Regex.run(~r{id="totp-secret">([A-Z2-7]+)<}, page, capture: :all_but_first)
        secret = Base.decode32!(secret32, padding: false)
        conn = post(recycle(conn), ~p"/2fa/setup", totp: %{code: totp_code(secret, -1)})
        assert redirected_to(conn) == ~p"/app"

        # Later: log out, choose the language, log in with password and 2FA.
        conn = delete(recycle(conn), ~p"/logout")
        conn = get(recycle(conn), ~p"/locale/#{locale}")
        login_page = html_response(get(recycle(conn), ~p"/login"), 200)
        assert login_page =~ ~s(dir="#{QPBX.Web.Locale.dir(locale)}")

        conn = post(recycle(conn), ~p"/login", login: %{email: email, password: password()})
        assert redirected_to(conn) == ~p"/2fa"
        user = Core.find_account_by_email(email)

        user =
          QPBX.Repo.update!(
            Ecto.Changeset.change(user, totp_last_used_at: ~U[2000-01-01 00:00:00Z])
          )

        conn = post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(user.totp_secret)})
        assert redirected_to(conn) == ~p"/app"

        home = html_response(get(recycle(conn), ~p"/app"), 200)
        assert home =~ "Acme #{locale}"
        assert home =~ ~s(lang="#{locale}")

        if locale == "ar" do
          assert home =~ ~s(dir="rtl")
          assert home =~ "المصادقة الثنائية مفعّلة"
        else
          assert home =~ "Two-factor authentication is on."
        end
      end
    end
  end

  test "creating a tenant with a taken admin email creates nothing", %{conn: conn} do
    {conn, _} = log_in_platform(conn)
    taken = user_fixture()
    plan = plan_fixture()
    {:ok, view, _} = live(conn, ~p"/platform/tenants/new")

    html =
      view
      |> form("#tenant-form",
        tenant: %{
          name: "Dup",
          slug: "dup-co",
          plan_id: plan.id,
          timezone: "UTC",
          locale: "en",
          admin_name: "X",
          admin_email: taken.email
        }
      )
      |> render_submit()

    assert html =~ "has already been taken"
    refute Enum.any?(Core.list_tenants(), &(&1.slug == "dup-co"))
  end

  test "a used setup link is refused", %{conn: conn} do
    {:ok, user} =
      Core.create_user(
        tenant_fixture(),
        %{email: "once@x.test", name: "O"},
        "tenant_admin",
        {:system, "test"}
      )

    path = URI.parse(QPBX.Web.setup_url(Core.setup_token(user))).path
    conn = put(conn, path, account: %{password: password(), password_confirmation: password()})
    assert redirected_to(conn) == ~p"/2fa/setup"
    assert get(build_conn(), path) |> redirected_to() == ~p"/login"
  end

  test "the language switch only redirects to same-site paths", %{conn: conn} do
    conn =
      conn
      |> put_req_header("referer", "https://evil.example//evil.example/x")
      |> get(~p"/locale/ar")

    assert redirected_to(conn) == ~p"/login"
  end
end
