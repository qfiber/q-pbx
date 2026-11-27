defmodule QPBX.Edge.SettingsTest do
  use QPBX.DataCase, async: false
  alias QPBX.Edge
  alias QPBX.Events.ConfigChanged

  @actor {:system, "test"}

  test "defaults, saved and announced; Kamailio's view follows" do
    QPBX.Events.subscribe(ConfigChanged)
    assert %{register_per_minute: 30, ban_seconds: 3600} = Edge.get_settings()

    assert {:ok, %{register_per_minute: 60}} =
             Edge.update_settings(
               %{register_per_minute: 60, scanner_agents: "sipvicious|friendly-scanner"},
               @actor
             )

    assert_receive {:event, %ConfigChanged{kind: "edge_settings"}}
    %{rows: rows} = Repo.query!("SELECT key_name, value_type, key_value FROM kamailio.settings")
    assert ["register_per_minute", 1, "60"] in rows
    assert ["scanner_agents", 0, "sipvicious|friendly-scanner"] in rows
    assert Enum.any?(QPBX.Core.list_audit_logs(), &(&1.action == "edge_settings.update"))
  end

  test "ranges are enforced" do
    assert {:error, cs} =
             Edge.update_settings(
               %{ban_seconds: 10, flood_requests: 0, auth_failures_port: 2},
               @actor
             )

    assert errors_on(cs)[:ban_seconds] && errors_on(cs)[:flood_requests] &&
             errors_on(cs)[:auth_failures_port]

    assert {:error, cs} = Edge.update_settings(%{ban_seconds: 2_592_001}, @actor)
    assert errors_on(cs)[:ban_seconds]
  end

  test "scanner names: no empty name (it would match every phone), no regular expression syntax" do
    for bad <- ["", "sipvicious|", "|sipvicious", "a||b", "ab", ".*", "sip(vicious)", "x[1]"] do
      assert {:error, cs} = Edge.update_settings(%{scanner_agents: bad}, @actor), inspect(bad)
      assert errors_on(cs)[:scanner_agents]
    end

    assert {:ok, _} =
             Edge.update_settings(
               %{scanner_agents: "friendly-scanner|VaxSIPUserAgent|sip scan 1.0"},
               @actor
             )
  end
end
