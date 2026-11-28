defmodule QPBX.Web.DashboardTest do
  @moduledoc "The dashboards: the numbers at a glance, each card opening its page."
  use QPBX.Web.ConnCase, async: true
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.{Core, Notify}

  @actor {:system, "test"}

  defp signed_in(conn, account, login_path) do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, login_path, login: %{email: account.email, password: password()})
    conn = post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)})
    {recycle(conn), account}
  end

  test "a tenant admin's dashboard: users, extensions, alerts; each card links to its page",
       %{conn: conn} do
    t = tenant_fixture()
    admin = user_fixture(t, "tenant_admin", %{name: "Dana Levi"})
    s = Core.scope_for(admin)
    for n <- ~w(101 102), do: {:ok, _} = Core.create_extension(s, %{number: n, name: n}, @actor)

    {:ok, _} =
      Notify.raise_alert(%{
        kind: "fraud_block",
        key: "f:1",
        tenant_id: t.id,
        title: "Calls blocked",
        message: "x"
      })

    {conn, _} = signed_in(conn, admin, ~p"/login")
    {:ok, view, html} = live(conn, ~p"/app")
    assert html =~ "Hello, Dana"
    assert view |> element("#stat-users") |> render() =~ ~r/>\s*1\s*</
    assert view |> element("#stat-online") |> render() =~ "2 extensions"
    alerts = view |> element("#stat-alerts") |> render()
    assert alerts =~ "1 critical" and alerts =~ "border-error"
    assert view |> element("#recent-alerts") |> render() =~ "Calls blocked"

    assert view
           |> element("#stat-calls")
           |> render_click()
           |> follow_redirect(conn, ~p"/app/calls")
  end

  test "a tenant user's dashboard: their extension, voicemail and notifications", %{conn: conn} do
    t = tenant_fixture()
    {conn, _} = signed_in(conn, user_fixture(t, "tenant_user"), ~p"/login")
    {:ok, view, _} = live(conn, ~p"/app")
    assert has_element?(view, "#stat-extension")
    refute has_element?(view, "#stat-users")

    assert view
           |> element("#stat-notifications")
           |> render_click()
           |> follow_redirect(conn, ~p"/app/notifications")
  end

  test "the platform dashboard: tenants, health and alerts; the tenants list moved to /platform/tenants",
       %{conn: conn} do
    tenant_fixture()
    {conn, _} = signed_in(conn, platform_admin_fixture(), ~p"/platform/login")
    {:ok, view, html} = live(conn, ~p"/platform")
    assert html =~ "Platform overview"
    assert has_element?(view, "#stat-health")
    assert has_element?(view, "#health")

    assert view
           |> element("#stat-tenants")
           |> render_click()
           |> follow_redirect(conn, ~p"/platform/tenants")
  end
end
