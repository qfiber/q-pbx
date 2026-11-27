defmodule QPBX.Core.ScopeTest do
  @moduledoc "Row-level security in force: a tenant scope cannot see other tenants' rows."
  use QPBX.DataCase, async: true
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Core.{Scope, Tenant, User, UserSession}

  setup do
    a = user_fixture(tenant_fixture(), "tenant_admin")
    b = user_fixture(tenant_fixture(), "tenant_admin")
    Core.create_session(a)
    Core.create_session(b)
    %{a: a, b: b, scope_a: Core.scope_for(a)}
  end

  test "even a query with no tenant filter sees only the scope's tenant", %{
    a: a,
    b: b,
    scope_a: scope
  } do
    {users, tenants, sessions} =
      Scope.run(scope, fn ->
        # Deliberately unfiltered, as a bug would be.
        {Repo.all(from u in User, select: u.tenant_id), Repo.all(from t in Tenant, select: t.id),
         Repo.all(from s in UserSession, select: s.tenant_id)}
      end)

    assert Enum.uniq(users) == [a.tenant_id]
    assert tenants == [a.tenant_id]
    assert Enum.uniq(sessions) == [a.tenant_id]
    refute b.tenant_id in users
  end

  test "scoped Core reads return only the tenant's own data", %{a: a, scope_a: scope} do
    assert [%{id: id}] = Core.list_users(scope)
    assert id == a.id
    assert Core.my_tenant(scope).id == a.tenant_id
    assert [_] = Core.list_my_sessions(scope)
  end

  test "the platform scope sees every tenant", %{a: a, b: b} do
    admin = platform_admin_fixture()
    ids = Scope.run(Core.scope_for(admin), fn -> Repo.all(from t in Tenant, select: t.id) end)
    assert a.tenant_id in ids and b.tenant_id in ids
  end

  test "writing another tenant's row from a tenant scope is refused", %{b: b, scope_a: scope} do
    assert_raise Postgrex.Error, ~r/row-level security/, fn ->
      Scope.run(scope, fn ->
        Repo.insert!(%User{tenant_id: b.tenant_id, email: "x@y.test", name: "X"})
      end)
    end
  end
end
