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
end
