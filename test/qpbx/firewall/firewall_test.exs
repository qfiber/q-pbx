defmodule QPBX.FirewallTest do
  # Not async: the shared sandbox lets the Sync process (started by the app) use the DB too.
  use QPBX.DataCase, async: false
  import QPBX.Fixtures
  alias QPBX.Core.AuditLog
  alias QPBX.Firewall
  alias QPBX.Firewall.{CIDR, Sets, Sync}

  @actor {:system, "test"}

  setup do
    QPBX.FakeHelper.reset()
    :ok
  end

  # Every change broadcasts an event; Sync.status/0 returns once the Sync process has
  # handled it, so nothing touches the DB after the test's sandbox is gone.
  defp create(attrs, actor),
    do: tap(Firewall.create_entry(attrs, actor), fn _ -> Sync.status() end)

  defp settle_delete(e, actor),
    do: tap(Firewall.delete_entry(e, actor), fn _ -> Sync.status() end)

  defp entry(attrs) do
    {:ok, e} =
      create(
        Enum.into(attrs, %{level: "platform", kind: "allow", scope: "all", reason: "test"}),
        @actor
      )

    e
  end

  describe "CIDR.parse/1" do
    test "canonicalizes addresses and prefixes" do
      assert {:ok, "203.0.113.7", :v4, 32} = CIDR.parse("203.0.113.7")
      assert {:ok, "10.0.0.0/8", :v4, 8} = CIDR.parse("10.1.2.3/8")
      assert {:ok, "2001:db8::/32", :v6, 32} = CIDR.parse("2001:DB8:1::5/32")
      assert {:ok, "2001:db8::1", :v6, 128} = CIDR.parse(" 2001:db8::1 ")
    end

    test "refuses everything else" do
      for bad <- [
            "",
            "1.2.3",
            "999.1.1.1",
            "1.2.3.4/33",
            "1.2.3.4/x",
            "1.2.3.4/8/8",
            "fe80::1%eth0",
            "host.example",
            "1.2.3.4; drop"
          ] do
        assert CIDR.parse(bad) == :error, bad
      end
    end
  end

  describe "entries" do
    test "creating one is audited and the desired sets follow scope and family" do
      e = entry(cidr: "198.51.100.0/24", scope: "all")
      entry(cidr: "2001:db8::/48", scope: "sip")
      entry(cidr: "192.0.2.66", kind: "block", scope: "sip")

      assert Repo.get_by!(AuditLog, action: "firewall_entry.create", target_id: e.id)

      desired = Sets.desired(Firewall.list_entries())
      assert desired["allow_ssh_v4"] == ["198.51.100.0/24"]
      assert desired["allow_sip_v4"] == ["198.51.100.0/24"]
      assert desired["allow_https_v4"] == ["198.51.100.0/24"]
      assert desired["allow_sip_v6"] == ["2001:db8::/48"]
      assert desired["block_sip_v4"] == ["192.0.2.66"]
      assert desired["block_ssh_v4"] == []
      assert map_size(desired) == 12
    end

    test "validation: duplicates, levels, expiry in the past" do
      entry(cidr: "198.51.100.1")

      assert {:error, cs} =
               create(
                 %{
                   level: "platform",
                   kind: "allow",
                   scope: "all",
                   cidr: "198.51.100.1",
                   reason: "x"
                 },
                 @actor
               )

      assert errors_on(cs)[:level] || errors_on(cs)[:cidr] || errors_on(cs)[:kind]

      past = DateTime.add(DateTime.utc_now(), -60)

      assert {:error, cs} =
               create(
                 %{
                   level: "platform",
                   kind: "allow",
                   scope: "all",
                   cidr: "198.51.100.2",
                   reason: "x",
                   expires_at: past
                 },
                 @actor
               )

      assert errors_on(cs)[:expires_at]

      assert {:error, cs} =
               create(
                 %{level: "platform", kind: "allow", scope: "all", cidr: "nope", reason: "x"},
                 @actor
               )

      assert errors_on(cs)[:cidr]
    end

    test "tenant entries: SIP allow only, narrow prefixes only" do
      t = tenant_fixture()
      base = %{level: "tenant", tenant_id: t.id, kind: "allow", scope: "sip", reason: "office"}
      assert {:ok, _} = create(Map.put(base, :cidr, "203.0.113.0/24"), @actor)
      assert {:error, cs} = create(Map.put(base, :cidr, "0.0.0.0/0"), @actor)
      assert errors_on(cs)[:cidr]

      assert {:error, cs} =
               create(
                 %{base | scope: "ssh"} |> Map.put(:cidr, "203.0.113.9"),
                 @actor
               )

      assert errors_on(cs)[:scope]

      assert {:error, cs} =
               create(
                 %{base | kind: "block"} |> Map.put(:cidr, "203.0.113.9"),
                 @actor
               )

      assert errors_on(cs)[:kind]

      assert {:error, cs} =
               create(
                 %{base | level: "tenant", tenant_id: nil} |> Map.put(:cidr, "203.0.113.9"),
                 @actor
               )

      assert errors_on(cs)[:tenant_id]
    end

    test "the last management entry cannot be removed" do
      a = entry(cidr: "198.51.100.1", scope: "ssh")
      b = entry(cidr: "198.51.100.2", scope: "all")
      sip_only = entry(cidr: "198.51.100.3", scope: "sip")

      assert {:ok, _} = settle_delete(a, @actor)
      assert {:error, :last_management_entry} = settle_delete(b, @actor)
      assert {:ok, _} = settle_delete(sip_only, @actor)

      # An expiring entry does not count as a replacement.
      entry(
        cidr: "198.51.100.4",
        scope: "all",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      )

      assert {:error, :last_management_entry} = settle_delete(b, @actor)
      assert Repo.get_by!(AuditLog, action: "firewall_entry.delete", target_id: a.id)
    end
  end

  describe "sync" do
    test "replaces every managed set through the helper and drops expired entries" do
      entry(cidr: "198.51.100.0/24", scope: "ssh")

      soon =
        entry(
          cidr: "192.0.2.10",
          kind: "block",
          scope: "https",
          expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      assert %{errors: [], skipped: []} = Sync.reconcile()
      sets = QPBX.FakeHelper.sets()
      assert sets["allow_ssh_v4"] == ["198.51.100.0/24"]
      assert sets["block_https_v4"] == ["192.0.2.10"]
      assert sets["allow_sip_v4"] == []
      assert map_size(sets) == 12

      Repo.update!(
        Ecto.Changeset.change(soon,
          expires_at: DateTime.add(DateTime.utc_now(), -1) |> DateTime.truncate(:second)
        )
      )

      Sync.reconcile()
      assert QPBX.FakeHelper.sets()["block_https_v4"] == []
    end

    test "never empties the SSH allow sets when the database has no management entry" do
      entry(cidr: "192.0.2.10", kind: "block", scope: "sip")
      assert %{skipped: ["allow_ssh_v4", "allow_ssh_v6"]} = Sync.reconcile()
      refute Map.has_key?(QPBX.FakeHelper.sets(), "allow_ssh_v4")
    end

    test "helper errors are reported, not raised" do
      entry(cidr: "198.51.100.1", scope: "ssh")
      QPBX.FakeHelper.fail_with("nft: boom")
      assert %{errors: [{_, "nft: boom"} | _]} = Sync.reconcile()
    end

    test "a change is broadcast and the running Sync process applies it" do
      # entry/1 publishes the event and waits for the running Sync process to handle it.
      entry(cidr: "203.0.113.50", scope: "ssh")
      assert QPBX.FakeHelper.sets()["allow_ssh_v4"] == ["203.0.113.50"]
    end
  end
end
