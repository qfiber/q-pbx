defmodule QPBX.Core.TelephonyConfigTest do
  use QPBX.DataCase, async: false
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Core.Scope
  alias QPBX.Events.{ConfigChanged, SipCredentialsChanged}

  @actor {:system, "test"}

  setup do
    plan = plan_fixture(max_extensions: 2)
    t = tenant_fixture(plan_id: plan.id)
    other = tenant_fixture()

    %{
      t: t,
      scope: Core.scope_for(user_fixture(t)),
      other: Core.scope_for(user_fixture(other)),
      platform: Core.scope_for(platform_admin_fixture())
    }
  end

  defp ext!(scope, number),
    do: elem(Core.create_extension(scope, %{number: number, name: "E#{number}"}, @actor), 1)

  defp trunk!(scope, host, attrs \\ %{}) do
    {:ok, trunk} =
      Core.create_trunk(
        scope,
        Map.merge(%{name: "T #{host}", auth_mode: "ip", addresses: [%{host: host}]}, attrs),
        @actor
      )

    trunk
  end

  describe "extensions and devices" do
    test "create within the plan limit, announced; isolated from other tenants", %{
      scope: scope,
      other: other
    } do
      QPBX.Events.subscribe(ConfigChanged)
      e = ext!(scope, "101")
      assert_receive {:event, %ConfigChanged{kind: "extensions"}}
      _ = ext!(scope, "102")
      assert {:error, cs} = Core.create_extension(scope, %{number: "103", name: "x"}, @actor)
      assert errors_on(cs)[:number] == ["the plan allows 2 extensions"]
      assert {:error, cs} = Core.create_extension(other, %{number: "0101", name: "x"}, @actor)
      assert errors_on(cs)[:number]
      assert_raise Ecto.NoResultsError, fn -> Core.get_extension!(other, e.id) end
      assert Core.list_extensions(other) == []
    end

    test "feature fields are validated", %{scope: scope} do
      e = ext!(scope, "101")

      assert {:ok, e} =
               Core.update_extension(
                 scope,
                 e,
                 %{
                   dnd: true,
                   forward_busy: "+97221234567",
                   follow_me_numbers: ["102", "+972501234567"]
                 },
                 @actor
               )

      assert e.dnd

      assert {:error, cs} =
               Core.update_extension(
                 scope,
                 e,
                 %{forward_always: "02-123", no_answer_seconds: 1},
                 @actor
               )

      assert errors_on(cs)[:forward_always] && errors_on(cs)[:no_answer_seconds]
    end

    test "a device has its own SIP login, shown once; deleting removes it", %{t: t, scope: scope} do
      QPBX.Events.subscribe(SipCredentialsChanged)
      e = ext!(scope, "101")

      assert {:ok, d, password} =
               Core.add_device(
                 scope,
                 e,
                 %{label: "desk", kind: "desk_phone", mac: "00:0B:82:AA:BB:CC"},
                 @actor
               )

      assert d.mac == "000b82aabbcc"
      assert d.sip_credential.username == "101-desk"
      assert String.length(password) == 24
      assert_receive {:event, %SipCredentialsChanged{}}
      %{rows: rows} = Repo.query!("SELECT key_name FROM kamailio.credentials")
      assert ["101-desk@#{t.sip_domain}"] in rows

      assert {:error, cs} = Core.add_device(scope, e, %{label: "desk", kind: "softphone"}, @actor)
      assert errors_on(cs)[:label]
      assert {:ok, _, new} = Core.reset_device_password(scope, d.id, @actor)
      refute new == password
      {:ok, _} = Core.delete_device(scope, d.id, @actor)
      assert Core.list_sip_credentials(scope) == []
    end

    test "one device may log in as the extension number itself", %{t: t, scope: scope} do
      e = ext!(scope, "105")
      assert {:ok, d, _} = Core.add_device(scope, e, %{label: "", kind: "softphone"}, @actor)
      assert d.label == "" and d.sip_credential.username == "105"
      %{rows: rows} = Repo.query!("SELECT key_name FROM kamailio.credentials")
      assert ["105@#{t.sip_domain}"] in rows
      assert {:error, cs} = Core.add_device(scope, e, %{kind: "desk_phone"}, @actor)
      assert errors_on(cs)[:label]
      assert {:ok, _, _} = Core.add_device(scope, e, %{label: "desk", kind: "desk_phone"}, @actor)
    end

    test "deleting an extension removes its devices' logins", %{scope: scope} do
      e = ext!(scope, "101")
      {:ok, _, _} = Core.add_device(scope, e, %{label: "a", kind: "softphone"}, @actor)
      {:ok, _, _} = Core.add_device(scope, e, %{label: "b", kind: "mobile"}, @actor)
      {:ok, _} = Core.delete_extension(scope, e, @actor)
      assert Core.list_sip_credentials(scope) == []
    end
  end

  describe "trunks" do
    test "platform trunk with several addresses; registration needs a login, stored encrypted", %{
      platform: p
    } do
      t =
        trunk!(p, "192.0.2.10", %{
          addresses: [
            %{host: "192.0.2.10", priority: 1},
            %{host: "sip.carrier.example", priority: 2, transport: "tcp"}
          ]
        })

      assert length(t.addresses) == 2

      assert {:error, cs} =
               Core.create_trunk(
                 p,
                 %{name: "R", auth_mode: "registration", addresses: [%{host: "sip.x.example"}]},
                 @actor
               )

      assert errors_on(cs)[:username] && errors_on(cs)[:password]

      {:ok, r} =
        Core.create_trunk(
          p,
          %{
            name: "R",
            auth_mode: "registration",
            username: "u",
            password: "s3cret-pass",
            addresses: [%{host: "sip.x.example"}]
          },
          @actor
        )

      %{rows: [[raw]]} =
        Repo.query!("SELECT password FROM trunks WHERE id = $1", [Ecto.UUID.dump!(r.id)])

      refute raw =~ "s3cret-pass"
      assert Core.get_trunk!(p, r.id).password == "s3cret-pass"
      refute Enum.any?(Repo.all(QPBX.Core.AuditLog), &Map.has_key?(&1.changes, "password"))
    end

    test "bad addresses and own-number caller ID rules", %{platform: p} do
      assert {:error, cs} =
               Core.create_trunk(
                 p,
                 %{name: "X", auth_mode: "ip", addresses: [%{host: "not a host"}]},
                 @actor
               )

      assert errors_on(cs)[:addresses]

      assert {:error, cs} =
               Core.create_trunk(
                 p,
                 %{
                   name: "X",
                   auth_mode: "ip",
                   caller_id_mode: "own_number",
                   addresses: [%{host: "192.0.2.1"}]
                 },
                 @actor
               )

      assert errors_on(cs)[:default_caller_id]

      assert {:error, cs} =
               Core.create_trunk(p, %{name: "X", auth_mode: "ip", addresses: []}, @actor)

      assert errors_on(cs)[:addresses]
    end

    test "an IP trunk address belongs to one IP trunk across tenants", %{
      platform: p,
      scope: scope
    } do
      _ = trunk!(p, "192.0.2.20")

      assert {:error, cs} =
               Core.create_trunk(
                 scope,
                 %{name: "Mine", auth_mode: "ip", addresses: [%{host: "192.0.2.20"}]},
                 @actor
               )

      assert errors_on(cs)[:addresses] == ["an address is already used by another IP trunk"]
      mine = trunk!(scope, "198.51.100.5")
      assert [%{id: id}] = Core.list_trunks(scope)
      assert id == mine.id
      refute Enum.any?(Core.list_trunks(p), &(&1.id == mine.id))
    end
  end

  describe "DIDs" do
    test "platform assigns, tenant points it at its own extension only", %{
      t: t,
      scope: scope,
      other: other,
      platform: p
    } do
      trunk = trunk!(p, "192.0.2.30")

      {:ok, did} =
        Core.create_did(p, %{number: "+97221234567", trunk_id: trunk.id, tenant_id: t.id}, @actor)

      {:ok, backup} =
        Core.create_did(
          p,
          %{number: "+97231234567", trunk_id: trunk.id, alias_of_id: did.id},
          @actor
        )

      assert backup.tenant_id == t.id
      e = ext!(scope, "101")

      assert {:ok, did} =
               Core.set_did_destination(
                 scope,
                 Core.get_did!(scope, did.id),
                 %{destination_type: "extension", destination_id: e.id},
                 @actor
               )

      assert did.destination_id == e.id

      assert {:error, :backup_number} =
               Core.set_did_destination(
                 scope,
                 Core.get_did!(scope, backup.id),
                 %{destination_type: "external", destination_number: "+972501234567"},
                 @actor
               )

      foreign = ext!(other, "201")

      assert {:error, cs} =
               Core.set_did_destination(
                 scope,
                 did,
                 %{destination_type: "extension", destination_id: foreign.id},
                 @actor
               )

      assert errors_on(cs)[:destination_id]
      assert_raise Ecto.NoResultsError, fn -> Core.get_did!(other, did.id) end

      # Moving the number to another tenant clears its destination and moves its backup.
      other_tid = other.tenant_id
      {:ok, moved} = Core.update_did(p, did, %{tenant_id: other_tid}, @actor)
      assert moved.destination_type == nil
      assert Core.get_did!(p, backup.id).tenant_id == other_tid
    end

    test "numbers are E.164 and unique", %{platform: p} do
      trunk = trunk!(p, "192.0.2.31")
      assert {:error, cs} = Core.create_did(p, %{number: "021234567", trunk_id: trunk.id}, @actor)
      assert errors_on(cs)[:number]
      {:ok, _} = Core.create_did(p, %{number: "+97221234568", trunk_id: trunk.id}, @actor)

      assert {:error, cs} =
               Core.create_did(p, %{number: "+97221234568", trunk_id: trunk.id}, @actor)

      assert errors_on(cs)[:number]
    end
  end

  describe "outbound and emergency routes" do
    test "ordered trunks from the platform and the tenant's own; not another tenant's", %{
      scope: scope,
      other: other,
      platform: p
    } do
      shared = trunk!(p, "192.0.2.40")
      mine = trunk!(scope, "198.51.100.40")
      theirs = trunk!(other, "203.0.113.40")

      assert Enum.map(Core.trunk_choices(scope), & &1.id) |> Enum.sort() ==
               Enum.sort([shared.id, mine.id])

      {:ok, r} =
        Core.create_route(
          scope,
          %{
            name: "IL",
            prefixes: ["+972"],
            destination_class: "local",
            trunk_ids: [mine.id, shared.id]
          },
          @actor
        )

      assert Core.get_route!(scope, r.id).trunk_ids == [mine.id, shared.id]

      {:ok, _} =
        Core.update_route(scope, Core.get_route!(scope, r.id), %{trunk_ids: [shared.id]}, @actor)

      assert Core.get_route!(scope, r.id).trunk_ids == [shared.id]

      assert {:error, cs} =
               Core.create_route(
                 scope,
                 %{name: "X", destination_class: "local", trunk_ids: [theirs.id]},
                 @actor
               )

      assert errors_on(cs)[:trunk_ids]

      assert {:error, cs} =
               Core.create_route(
                 scope,
                 %{
                   name: "X",
                   destination_class: "lunar",
                   prefixes: ["972"],
                   trunk_ids: [shared.id]
                 },
                 @actor
               )

      assert errors_on(cs)[:destination_class] && errors_on(cs)[:prefixes]

      # A trunk in use cannot be deleted.
      assert {:error, cs} = Core.delete_trunk(p, shared, @actor)
      assert errors_on(cs)[:id]
    end

    test "emergency routes use platform trunks only", %{scope: scope, platform: p} do
      shared = trunk!(p, "192.0.2.50")
      mine = trunk!(scope, "198.51.100.50")

      assert {:ok, _} =
               Core.create_emergency_route(p, %{number: "100", trunk_id: shared.id}, @actor)

      assert {:error, cs} =
               Core.create_emergency_route(p, %{number: "101", trunk_id: mine.id}, @actor)

      assert errors_on(cs)[:trunk_id]

      assert {:error, cs} =
               Core.create_emergency_route(p, %{number: "100", trunk_id: shared.id}, @actor)

      assert errors_on(cs)[:number]
    end
  end

  describe "number rules and classes" do
    test "Israel by default; a platform default; a tenant override and its reset", %{
      scope: scope,
      platform: p
    } do
      assert Core.number_rule(scope).country_code == "972"
      assert Core.to_e164(scope, "02-123-4567") == {:ok, "+97221234567"}

      {:ok, _} =
        Core.put_number_rule(
          p,
          %{country_code: "44", national_prefix: "0", international_prefixes: ["00"]},
          @actor
        )

      assert Core.number_rule(scope).country_code == "44"
      {:ok, _} = Core.put_number_rule(scope, %{country_code: "972", area_code: "2"}, @actor)
      {:ok, _} = Core.put_number_rule(scope, %{country_code: "972", area_code: "3"}, @actor)
      assert Core.to_e164(scope, "1234567") == {:ok, "+97231234567"}
      {:ok, _} = Core.reset_number_rule(scope, @actor)
      assert Core.number_rule(scope).country_code == "44"
      assert {:error, cs} = Core.put_number_rule(scope, %{country_code: "+972"}, @actor)
      assert errors_on(cs)[:country_code]
    end

    test "class prefixes (the high-cost list is class premium)", %{platform: p} do
      {:ok, c} = Core.create_number_class(p, %{prefix: "+9725", class: "mobile"}, @actor)

      assert {:error, cs} =
               Core.create_number_class(p, %{prefix: "+9725", class: "mobile"}, @actor)

      assert errors_on(cs)[:prefix]

      assert {:error, cs} =
               Core.create_number_class(p, %{prefix: "+1900", class: "expensive"}, @actor)

      assert errors_on(cs)[:class]
      {:ok, _} = Core.delete_number_class(p, c.id, @actor)
      assert Core.list_number_classes() == []
    end
  end

  describe "Kamailio views" do
    test "dispatcher has IP trunks only, by priority; the trunks table names registrars", %{
      platform: p,
      scope: scope
    } do
      {:ok, ip} =
        Core.create_trunk(
          p,
          %{
            name: "IP",
            auth_mode: "ip",
            addresses: [
              %{host: "192.0.2.80", priority: 1},
              %{host: "2001:db8::5", port: 5080, transport: "tcp", priority: 2}
            ]
          },
          @actor
        )

      {:ok, reg} =
        Core.create_trunk(
          scope,
          %{
            name: "Reg",
            auth_mode: "registration",
            username: "u",
            password: "secret-pw",
            addresses: [%{host: "sip.reg.example"}]
          },
          @actor
        )

      assert is_integer(ip.edge_id) and reg.edge_id > ip.edge_id

      %{rows: rows} =
        Repo.query!(
          "SELECT setid, destination, priority, attrs FROM kamailio.dispatcher ORDER BY priority DESC"
        )

      assert [
               [sid, "sip:192.0.2.80:5060", 99, attrs],
               [sid, "sip:[2001:db8::5]:5080;transport=tcp", 98, _]
             ] = rows

      assert sid == ip.edge_id
      assert attrs == "weight=1;trunk=#{ip.id};edge=#{ip.edge_id}"

      %{rows: trunks} = Repo.query!("SELECT key_name, key_value FROM kamailio.trunks")
      assert ["#{ip.edge_id}", "#{ip.id};;ip;"] in trunks

      assert [
               "#{reg.edge_id}",
               "#{reg.id};#{scope.tenant_id};registration;sip:sip.reg.example:5060"
             ] in trunks

      assert ["reg:#{reg.id}", "#{reg.edge_id}"] in trunks
      refute Enum.any?(Repo.query!("SELECT * FROM kamailio.uacreg").rows)
    end

    test "allow list: platform and tenant SIP allows, not blocks or expired ones", %{scope: scope} do
      actor = @actor

      {:ok, _} =
        QPBX.Firewall.create_entry(
          %{
            level: "tenant",
            tenant_id: scope.tenant_id,
            kind: "allow",
            scope: "sip",
            cidr: "198.51.100.0/29",
            reason: "office"
          },
          actor
        )

      {:ok, _} =
        QPBX.Firewall.create_entry(
          %{level: "platform", kind: "block", scope: "sip", cidr: "203.0.113.9", reason: "bad"},
          actor
        )

      %{rows: rows} = Repo.query!("SELECT grp, ip_addr, mask, tag FROM kamailio.address")
      assert [2, "198.51.100.0", 29, scope.tenant_id] in rows
      refute Enum.any?(rows, fn [_, ip | _] -> ip == "203.0.113.9" end)
      # Let the firewall sync these entries started finish before the test's database goes.
      _ = QPBX.Firewall.sync_status()
    end
  end

  test "a platform scope is required for platform data", %{scope: scope} do
    assert_raise FunctionClauseError, fn -> Core.create_did(scope, %{}, @actor) end
    assert_raise FunctionClauseError, fn -> Core.create_emergency_route(scope, %{}, @actor) end
    assert %Scope{kind: :tenant} = scope
  end
end
