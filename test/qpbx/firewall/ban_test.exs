defmodule QPBX.Firewall.BanTest do
  use QPBX.DataCase, async: false
  alias QPBX.Firewall
  alias QPBX.Firewall.{Sets, Store}

  @actor {:system, "test"}

  setup do
    QPBX.FakeHelper.reset()
    :ok
  end

  # Bans publish FirewallChanged: let the global sync finish with this test's database
  # connection before the test ends.
  defp settle, do: _ = Firewall.sync_status()

  defp blocks, do: Firewall.list_entries(level: "platform") |> Enum.filter(&(&1.kind == "block"))

  test "an automatic ban is a SIP block with an expiry; a second ban extends it" do
    assert {:ok, e} = Firewall.ban("203.0.113.9", "flood", 3600, @actor)
    assert %{kind: "block", scope: "sip", reason: "auto: flood"} = e
    assert_in_delta DateTime.diff(e.expires_at, DateTime.utc_now()), 3600, 5
    assert {:ok, e2} = Firewall.ban("203.0.113.9", "auth failures", 7200, @actor)
    assert e2.id == e.id and DateTime.compare(e2.expires_at, e.expires_at) == :gt
    # A shorter ban never shortens it.
    assert {:ok, e3} = Firewall.ban("203.0.113.9", "scanner", 60, @actor)
    assert e3.expires_at == e2.expires_at
    assert length(blocks()) == 1
    settle()
  end

  test "IPv6 addresses are stored in canonical form (one entry however written)" do
    {:ok, _} = Firewall.ban("2001:DB8:0::5", "flood", 600, @actor)
    {:ok, _} = Firewall.ban("2001:db8::5", "flood", 600, @actor)
    assert [%{cidr: "2001:db8::5"}] = blocks()
    assert {:error, :invalid_address} = Firewall.ban("not-an-ip", "flood", 600, @actor)
    settle()
  end

  test "never bans the platform SIP allowlist or a tenant office IP; a permanent block stays" do
    {:ok, _} =
      Firewall.create_entry(
        %{
          level: "platform",
          kind: "allow",
          scope: "sip",
          cidr: "198.51.100.0/24",
          reason: "carrier"
        },
        @actor
      )

    tenant = QPBX.Fixtures.tenant_fixture()

    {:ok, _} =
      Firewall.create_entry(
        %{
          level: "tenant",
          tenant_id: tenant.id,
          kind: "allow",
          scope: "sip",
          cidr: "192.0.2.0/28",
          reason: "HQ"
        },
        @actor
      )

    assert {:ok, :allowlisted} = Firewall.ban("198.51.100.7", "flood", 600, @actor)
    assert {:ok, :office_ip} = Firewall.ban("192.0.2.3", "flood", 600, @actor)

    {:ok, _} =
      Firewall.create_entry(
        %{level: "platform", kind: "block", scope: "sip", cidr: "203.0.113.1", reason: "manual"},
        @actor
      )

    assert {:ok, %{expires_at: nil}} = Firewall.ban("203.0.113.1", "flood", 600, @actor)
    settle()
  end

  test "expiring blocks reach the helper with the seconds left; permanent ones without" do
    {:ok, _} = Firewall.ban("203.0.113.20", "flood", 600, @actor)

    {:ok, _} =
      Firewall.create_entry(
        %{level: "platform", kind: "block", scope: "all", cidr: "203.0.113.21", reason: "manual"},
        @actor
      )

    Firewall.sync_now()
    assert QPBX.FakeHelper.sets()["block_sip_v4"] == ["203.0.113.20", "203.0.113.21"]
    assert %{"203.0.113.20" => secs} = QPBX.FakeHelper.timeouts("block_sip_v4")
    assert secs in 590..600
    assert QPBX.FakeHelper.timeouts("block_https_v4") == %{}
    settle()
  end

  test "timeouts: an address with a permanent entry gets none; the longest expiry wins" do
    now = ~U[2026-01-01 00:00:00Z]

    e = fn cidr, exp ->
      %{kind: "block", scope: "sip", family: "v4", cidr: cidr, expires_at: exp}
    end

    entries = [
      e.("1.1.1.1", ~U[2026-01-01 00:10:00Z]),
      e.("1.1.1.1", ~U[2026-01-01 01:00:00Z]),
      e.("2.2.2.2", nil),
      e.("2.2.2.2", ~U[2026-01-01 00:10:00Z])
    ]

    assert Sets.timeouts(entries, now) == %{"block_sip_v4" => %{"1.1.1.1" => 3600}}
  end

  test "expired automatic bans are purged after a week; manual entries never" do
    {:ok, auto} = Firewall.ban("203.0.113.30", "flood", 60, @actor)

    {:ok, _} =
      Firewall.create_entry(
        %{
          level: "platform",
          kind: "block",
          scope: "sip",
          cidr: "203.0.113.31",
          reason: "manual",
          expires_at: DateTime.add(DateTime.utc_now(), 60)
        },
        @actor
      )

    assert {0, _} = Store.purge_expired_bans()
    assert {1, _} = Store.purge_expired_bans(DateTime.add(auto.expires_at, 8, :day))
    assert [%{cidr: "203.0.113.31"}] = blocks()
    settle()
  end
end
