defmodule QPBX.ReleaseTest do
  use QPBX.DataCase, async: false
  import ExUnit.CaptureIO
  import QPBX.Fixtures

  test "create_platform_admin prints a working setup link and audits it" do
    out = capture_io(fn -> QPBX.Release.create_platform_admin("ops@x.test", "Ops") end)
    token = out |> String.trim() |> String.split("/setup/") |> List.last()

    assert {:ok, %QPBX.Core.PlatformAdmin{email: "ops@x.test"}} =
             QPBX.Core.account_from_setup_token(token)

    assert Enum.any?(QPBX.Core.list_audit_logs(), &(&1.action == "account.setup_link_issued"))
  end

  test "setup_link prints a link for an existing tenant user" do
    user = user_fixture()
    out = capture_io(fn -> QPBX.Release.setup_link(user.email) end)
    assert out =~ "/setup/"
  end

  test "seed_management_ips adds entries once" do
    QPBX.FakeHelper.reset()
    out = capture_io(fn -> QPBX.Release.seed_management_ips(["198.51.100.0/24"]) end)
    assert out =~ "added 198.51.100.0/24"
    _ = QPBX.Firewall.sync_status()
    out = capture_io(fn -> QPBX.Release.seed_management_ips(["203.0.113.1"]) end)
    assert out =~ "already present"
    assert [%{cidr: "198.51.100.0/24", scope: "all"}] = QPBX.Firewall.list_entries()
  end

  test "list_sip_domains prints every tenant domain" do
    t = tenant_fixture(slug: "listme")
    assert capture_io(fn -> QPBX.Release.list_sip_domains() end) =~ t.sip_domain
  end

  test "revoke_sessions ends every session of an account" do
    user = user_fixture()
    QPBX.Core.create_session(user)
    QPBX.Core.create_session(user)
    assert capture_io(fn -> QPBX.Release.revoke_sessions(user.email) end) =~ "ended 2 sessions"
    assert QPBX.Core.list_sessions(user) == []
  end
end
