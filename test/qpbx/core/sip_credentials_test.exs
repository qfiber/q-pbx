defmodule QPBX.Core.SipCredentialsTest do
  use QPBX.DataCase, async: false
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Core.SipCredential
  alias QPBX.Events.{SipCredentialsChanged, TenantsChanged}

  @actor {:system, "test"}

  setup do
    tenant = tenant_fixture(slug: "t#{unique()}")
    %{tenant: tenant, scope: Core.scope_for(user_fixture(tenant, "tenant_admin"))}
  end

  test "creating a credential returns a generated password once and stores only HA1", %{
    tenant: t,
    scope: scope
  } do
    QPBX.Events.subscribe(SipCredentialsChanged)
    assert {:ok, cred, password} = Core.create_sip_credential(scope, %{username: "101"}, @actor)
    assert String.length(password) == 24
    assert password =~ ~r/\A[A-HJ-NP-Za-km-z2-9]+\z/

    assert cred.ha1 ==
             Base.encode16(:crypto.hash(:md5, "101:#{t.sip_domain}:#{password}"), case: :lower)

    refute Repo.query!("SELECT * FROM sip_credentials").rows
           |> List.flatten()
           |> Enum.member?(password)

    assert_receive {:event, %SipCredentialsChanged{tenant_id: tid}}
    assert tid == t.id
  end

  test "the same username in two tenants; unique within a tenant", %{scope: scope} do
    other = Core.scope_for(user_fixture(tenant_fixture(), "tenant_admin"))
    assert {:ok, _, _} = Core.create_sip_credential(scope, %{username: "101"}, @actor)
    assert {:ok, _, _} = Core.create_sip_credential(other, %{username: "101"}, @actor)
    assert {:error, cs} = Core.create_sip_credential(scope, %{username: "101"}, @actor)
    assert errors_on(cs)[:username]
    assert {:error, cs} = Core.create_sip_credential(scope, %{username: "bad name"}, @actor)
    assert errors_on(cs)[:username]
  end

  test "a reset changes the hash; delete removes it; the audit log never holds hashes", %{
    scope: scope
  } do
    {:ok, cred, old} = Core.create_sip_credential(scope, %{username: "102"}, @actor)
    {:ok, reset, new} = Core.reset_sip_password(scope, cred.id, @actor)
    refute old == new
    refute reset.ha1 == cred.ha1
    {:ok, _} = Core.delete_sip_credential(scope, cred.id, @actor)
    assert Core.list_sip_credentials(scope) == []
    for a <- Repo.all(QPBX.Core.AuditLog), do: refute(Map.has_key?(a.changes, "ha1"))
  end

  test "Kamailio's views: credentials by user@domain, only enabled ones; tenant domains", %{
    tenant: t,
    scope: scope
  } do
    {:ok, cred, _} = Core.create_sip_credential(scope, %{username: "103"}, @actor)
    {:ok, off, _} = Core.create_sip_credential(scope, %{username: "104"}, @actor)
    Repo.update!(Ecto.Changeset.change(off, enabled: false))

    %{rows: rows} =
      Repo.query!(
        "SELECT key_name, key_type, value_type, key_value, expires FROM kamailio.credentials"
      )

    assert ["103@#{t.sip_domain}", 0, 0, cred.ha1, 0] in rows
    refute Enum.any?(rows, fn [k | _] -> k == "104@#{t.sip_domain}" end)

    %{rows: domains} = Repo.query!("SELECT key_name, key_value FROM kamailio.domains")
    assert [t.sip_domain, t.id] in domains
  end

  test "passwords use the cryptographic generator: no repeats over many draws" do
    passwords = for _ <- 1..500, do: SipCredential.generate_password()
    assert length(Enum.uniq(passwords)) == 500
  end

  test "a tenant's slug (its SIP domain) cannot change after creation", %{tenant: t} do
    assert {:error, cs} = Core.update_tenant(t, %{slug: "renamed#{unique()}"}, @actor)
    assert errors_on(cs)[:slug]
    assert {:ok, _} = Core.update_tenant(t, %{name: "Renamed"}, @actor)
  end

  test "a new tenant is announced once, after its transaction commits" do
    QPBX.Events.subscribe(TenantsChanged)
    plan = plan_fixture()

    {:ok, %{tenant: t}} =
      Core.create_tenant_with_admin(
        %{name: "N", slug: "n#{unique()}", timezone: "UTC", locale: "en", plan_id: plan.id},
        %{email: "n#{unique()}@x.test", name: "N"},
        @actor
      )

    assert_receive {:event, %TenantsChanged{tenant_id: id}}
    assert id == t.id
    refute_receive {:event, %TenantsChanged{}}, 100
  end
end
