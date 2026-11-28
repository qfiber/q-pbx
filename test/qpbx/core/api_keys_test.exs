defmodule QPBX.Core.ApiKeysTest do
  use QPBX.DataCase, async: true
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Core.{ApiKey, AuditLog}

  @actor {:system, "test"}

  setup do
    t = tenant_fixture()
    %{t: t, scope: Core.scope_for(user_fixture(t))}
  end

  test "a key is shown once and only its hash is kept", %{scope: scope} do
    {:ok, key, token} = Core.create_api_key(scope, %{name: "CRM", scopes: ["read"]}, @actor)
    assert "qpbx_" <> _ = token
    assert key.prefix == String.slice(token, 0, 12)
    stored = Repo.get!(ApiKey, key.id)
    assert stored.token_hash == :crypto.hash(:sha256, token)
    refute Enum.any?(Map.values(Map.from_struct(stored)), &(&1 == token))
    assert {:ok, %ApiKey{id: id}} = Core.authenticate_api_key(token)
    assert id == key.id

    audit = Repo.get_by!(AuditLog, action: "api_key.create", target_id: key.id)
    refute Map.has_key?(audit.changes, "token_hash")
  end

  test "scopes must be known and at least one; expiry from the choice", %{scope: scope} do
    assert {:error, cs} = Core.create_api_key(scope, %{name: "x", scopes: []}, @actor)
    assert %{scopes: ["pick at least one scope"]} = errors_on(cs)
    assert {:error, cs} = Core.create_api_key(scope, %{name: "x", scopes: ["root"]}, @actor)
    assert %{scopes: [_]} = errors_on(cs)

    {:ok, key, _} =
      Core.create_api_key(scope, %{name: "x", scopes: ["read"], expires_in: "30"}, @actor)

    assert_in_delta DateTime.diff(key.expires_at, DateTime.utc_now(), :day), 30, 1

    {:ok, never, _} =
      Core.create_api_key(scope, %{name: "y", scopes: ["read"], expires_in: "never"}, @actor)

    assert never.expires_at == nil
  end

  test "expired, unknown and revoked keys are refused", %{scope: scope} do
    {:ok, key, token} = Core.create_api_key(scope, %{name: "x", scopes: ["read"]}, @actor)

    Repo.update_all(from(k in ApiKey, where: k.id == ^key.id),
      set: [expires_at: ~U[2020-01-01 00:00:00Z]]
    )

    assert {:error, :expired} = Core.authenticate_api_key(token)
    assert {:error, :invalid} = Core.authenticate_api_key("qpbx_nothing")
    assert {:error, :invalid} = Core.authenticate_api_key("Bearer x")

    {:ok, key, token} = Core.create_api_key(scope, %{name: "y", scopes: ["read"]}, @actor)
    assert {:ok, _} = Core.revoke_api_key(scope, key.id, @actor)
    assert {:error, :invalid} = Core.authenticate_api_key(token)
  end

  test "a tenant sees and revokes only its own keys; the platform only platform keys",
       %{scope: scope} do
    other = Core.scope_for(user_fixture(tenant_fixture()))
    platform = Core.scope_for(platform_admin_fixture())
    {:ok, mine, _} = Core.create_api_key(scope, %{name: "mine", scopes: ["read"]}, @actor)
    {:ok, theirs, _} = Core.create_api_key(other, %{name: "theirs", scopes: ["read"]}, @actor)
    {:ok, plat, _} = Core.create_api_key(platform, %{name: "plat", scopes: ["admin"]}, @actor)

    assert [%{id: id}] = Core.list_api_keys(scope)
    assert id == mine.id
    assert {:error, :not_found} = Core.revoke_api_key(scope, theirs.id, @actor)
    assert {:error, :not_found} = Core.revoke_api_key(scope, plat.id, @actor)
    assert Enum.map(Core.list_api_keys(platform), & &1.id) == [plat.id]
    assert {:error, :not_found} = Core.revoke_api_key(platform, mine.id, @actor)
    assert %Core.Scope{kind: :platform} = Core.scope_for(plat)
  end

  test "the rate limit comes from the plan, with the tenant's override" do
    t = tenant_fixture(plan_id: plan_fixture(%{api_rate_limit_per_minute: 7}).id)
    scope = Core.scope_for(user_fixture(t))
    {:ok, _, token} = Core.create_api_key(scope, %{name: "x", scopes: ["read"]}, @actor)
    {:ok, key} = Core.authenticate_api_key(token)
    assert Core.api_rate_limit(key) == 7

    {:ok, _} =
      Core.update_tenant(t, %{limit_overrides: %{"api_rate_limit_per_minute" => 3}}, @actor)

    {:ok, key} = Core.authenticate_api_key(token)
    assert Core.api_rate_limit(key) == 3
  end

  test "idempotency: claim, in progress, replay, mismatch; server errors are not kept",
       %{scope: scope} do
    {:ok, key, _} = Core.create_api_key(scope, %{name: "x", scopes: ["write"]}, @actor)
    assert :claimed = Core.idempotency_claim(key, "k1", "f1")
    assert :in_progress = Core.idempotency_claim(key, "k1", "f1")
    assert :mismatch = Core.idempotency_claim(key, "k1", "f2")
    :ok = Core.idempotency_finish(key, "k1", 201, ~s({"data":1}))
    assert {:replay, 201, ~s({"data":1})} = Core.idempotency_claim(key, "k1", "f1")

    assert :claimed = Core.idempotency_claim(key, "k2", "f1")
    :ok = Core.idempotency_finish(key, "k2", 500, "boom")
    assert :claimed = Core.idempotency_claim(key, "k2", "f1")

    # Another key's identical Idempotency-Key is its own.
    {:ok, key2, _} = Core.create_api_key(scope, %{name: "y", scopes: ["write"]}, @actor)
    assert :claimed = Core.idempotency_claim(key2, "k1", "f9")
  end
end
