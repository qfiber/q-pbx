defmodule QPBX.Web.Platform.FirewallLiveTest do
  use QPBX.Web.ConnCase, async: false
  import Phoenix.LiveViewTest
  import QPBX.Fixtures

  setup %{conn: conn} do
    QPBX.FakeHelper.reset()
    admin = platform_admin_fixture()
    secret = QPBX.Core.new_totp_secret()
    {:ok, admin} = QPBX.Core.enable_totp(admin, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(admin, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, ~p"/platform/login", login: %{email: admin.email, password: password()})
    conn = post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)})
    {:ok, conn: recycle(conn)}
  end

  test "an allowlist entry added in the portal reaches the helper", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/platform/firewall")

    html =
      view
      |> form("#firewall-form",
        entry: %{cidr: "198.51.100.7", kind: "allow", scope: "ssh", reason: "office VPN"}
      )
      |> render_submit()

    assert html =~ "198.51.100.7"
    _ = QPBX.Firewall.sync_status()
    assert QPBX.FakeHelper.sets()["allow_ssh_v4"] == ["198.51.100.7"]

    [entry] = QPBX.Firewall.list_entries()
    html = view |> element("#delete-#{entry.id}") |> render_click()
    assert html =~ "last management IP"
  end

  test "invalid input shows errors", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/platform/firewall")

    html =
      view |> form("#firewall-form", entry: %{cidr: "not-an-ip", reason: "x"}) |> render_submit()

    assert html =~ "is not a valid IP address or prefix"
  end
end
