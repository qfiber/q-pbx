defmodule QPBX.Core do
  @moduledoc """
  Public API of the core area: tenants, plans, limits, users, roles and the audit log.
  See `lib/qpbx/core/README.md`.

  Every function that changes data takes an `actor` (a `PlatformAdmin`, a `User`, or
  `{:system, name}`) and writes an audit entry in the same transaction.
  """
  use Boundary,
    deps: [QPBX.Repo, QPBX.Events],
    exports: [
      Plan,
      Tenant,
      PlatformAdmin,
      User,
      AuditLog,
      Vault,
      UserSession,
      SessionSweeper,
      Scope,
      KeyProvider,
      SipCredential
    ]

  import Ecto.Query
  alias Ecto.Multi
  alias QPBX.Core.{Accounts, Audit, AuditLog, Plan, Tenant}
  alias QPBX.Repo

  ## Plans

  def list_plans, do: Repo.all(from p in Plan, order_by: p.name)
  def get_plan!(id), do: Repo.get!(Plan, id)
  def change_plan(%Plan{} = plan \\ %Plan{}, attrs \\ %{}), do: Plan.changeset(plan, attrs)

  def create_plan(attrs, actor),
    do: save(:insert, Plan.changeset(%Plan{}, attrs), "plan.create", actor)

  def update_plan(%Plan{} = plan, attrs, actor),
    do: save(:update, Plan.changeset(plan, attrs), "plan.update", actor)

  ## Tenants

  def list_tenants, do: Repo.all(from t in Tenant, order_by: t.name, preload: :plan)
  def get_tenant!(id), do: Tenant |> Repo.get!(id) |> Repo.preload(:plan)

  def change_tenant(%Tenant{} = tenant \\ %Tenant{}, attrs \\ %{}),
    do: Tenant.changeset(tenant, attrs, sip_base_domain())

  def create_tenant(attrs, actor) do
    save(:insert, Tenant.changeset(%Tenant{}, attrs, sip_base_domain()), "tenant.create", actor)
    |> tenant_changed()
  end

  def update_tenant(%Tenant{} = tenant, attrs, actor) do
    save(:update, Tenant.changeset(tenant, attrs, sip_base_domain()), "tenant.update", actor)
    |> tenant_changed()
  end

  # Kamailio learns new tenant domains through this event (QPBX.Edge). Inside an outer
  # transaction the row is not visible yet, so the caller announces after its commit.
  defp tenant_changed({:ok, %Tenant{id: id}} = ok) do
    unless Repo.in_transaction?(), do: announce_tenant(id)
    ok
  end

  defp tenant_changed(error), do: error

  defp announce_tenant(id),
    do: QPBX.Events.publish(%QPBX.Events.TenantsChanged{tenant_id: id, at: DateTime.utc_now()})

  @doc """
  Creates a tenant and its first tenant admin in one transaction, so a tenant never exists
  without an admin. Returns `{:ok, %{tenant: t, admin: u}}` or `{:error, :tenant | :admin, changeset}`.
  """
  def create_tenant_with_admin(tenant_attrs, admin_attrs, actor) do
    Repo.transaction(fn ->
      with {:ok, tenant} <- create_tenant(tenant_attrs, actor) |> tag(:tenant),
           {:ok, admin} <-
             Accounts.create_user(tenant, admin_attrs, "tenant_admin", actor) |> tag(:admin) do
        %{tenant: Repo.preload(tenant, :plan), admin: admin}
      else
        {:error, step, cs} -> Repo.rollback({step, cs})
      end
    end)
    |> case do
      {:ok, result} ->
        announce_tenant(result.tenant.id)
        {:ok, result}

      {:error, {step, cs}} ->
        {:error, step, cs}
    end
  end

  defp tag({:ok, v}, _step), do: {:ok, v}
  defp tag({:error, cs}, step), do: {:error, step, cs}

  @doc """
  The limits in force for a tenant: the plan's limits with the tenant's overrides on top.
  Returns a map of limit name (atom) to integer, or nil for unlimited.
  """
  def effective_limits(%Tenant{} = tenant) do
    tenant = Repo.preload(tenant, :plan)
    overrides = Map.new(tenant.limit_overrides, fn {k, v} -> {to_limit(k), v} end)
    tenant.plan |> Map.take(Plan.limits()) |> Map.merge(overrides)
  end

  defp to_limit(k) when is_atom(k), do: k
  defp to_limit(k), do: Enum.find(Plan.limits(), &(Atom.to_string(&1) == k))

  @doc "Language codes the installation offers (config `:qpbx, :locales`)."
  def locales, do: Enum.map(Application.fetch_env!(:qpbx, :locales), & &1.code)

  def sip_base_domain, do: Application.fetch_env!(:qpbx, :sip_base_domain)

  ## Accounts

  defdelegate create_platform_admin(attrs, actor), to: Accounts
  defdelegate create_user(tenant, attrs, role, actor), to: Accounts
  defdelegate change_user(attrs \\ %{}), to: Accounts
  defdelegate change_platform_admin(attrs \\ %{}), to: Accounts
  defdelegate get_platform_admin(id), to: Accounts
  defdelegate get_user(id), to: Accounts
  defdelegate find_account_by_email(email), to: Accounts
  defdelegate authenticate_platform_admin(email, password), to: Accounts
  defdelegate authenticate_user(email, password), to: Accounts
  defdelegate setup_token(account), to: Accounts
  defdelegate account_from_setup_token(token), to: Accounts
  defdelegate change_password(account, attrs \\ %{}), to: Accounts
  defdelegate complete_setup(account, attrs), to: Accounts
  defdelegate new_totp_secret(), to: Accounts
  defdelegate totp_uri(account, secret), to: Accounts
  defdelegate totp_enabled?(account), to: Accounts
  defdelegate requires_totp?(account), to: Accounts
  defdelegate totp_optional?(account), to: Accounts
  defdelegate enable_totp(account, secret, code), to: Accounts
  defdelegate verify_totp(account, code), to: Accounts

  ## Sessions (see QPBX.Core.Sessions)

  defdelegate create_session(account, meta \\ %{}), to: QPBX.Core.Sessions, as: :create
  defdelegate fetch_session(token, opts \\ []), to: QPBX.Core.Sessions, as: :fetch
  defdelegate list_sessions(account), to: QPBX.Core.Sessions, as: :list
  defdelegate revoke_session(account, session_id, actor), to: QPBX.Core.Sessions, as: :revoke
  defdelegate revoke_sessions(account, actor, opts \\ []), to: QPBX.Core.Sessions, as: :revoke_all
  defdelegate end_session(token), to: QPBX.Core.Sessions, as: :delete_by_token
  defdelegate session_idle_timeout(), to: QPBX.Core.Sessions, as: :idle_timeout

  ## Login limits (see QPBX.Core.LoginGuard)

  defdelegate login_check(ip), to: QPBX.Core.LoginGuard, as: :check
  defdelegate login_failed(ip, account \\ nil), to: QPBX.Core.LoginGuard, as: :failure
  defdelegate login_succeeded(ip), to: QPBX.Core.LoginGuard, as: :success

  ## Audit log

  @doc "Records an audit entry for a change made outside `QPBX.Core` (for example the firewall)."
  def audit(actor, action, target, changes),
    do: actor |> Audit.entry(action, target, changes) |> Repo.insert()

  def list_audit_logs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    query = from a in AuditLog, order_by: [desc: a.inserted_at], limit: ^limit

    case Keyword.fetch(opts, :tenant_id) do
      {:ok, id} -> Repo.all(from a in query, where: a.tenant_id == ^id)
      :error -> Repo.all(query)
    end
  end

  ## Scoped reads (row-level security in force for tenant scopes)

  alias QPBX.Core.Scope

  @doc "The scope a signed-in account acts in."
  defdelegate scope_for(account), to: Scope, as: :for_account

  @doc "The users of the scope's tenant (a platform scope must name the tenant)."
  # Explicit tenant filter and, on top, row-level security from the scope.
  def list_users(%Scope{kind: :tenant, tenant_id: id} = scope),
    do: Scope.run(scope, fn -> Accounts.list_users(%Tenant{id: id}) end)

  def list_users(%Scope{kind: :platform}, %Tenant{} = tenant), do: Accounts.list_users(tenant)

  @doc "The scope's own tenant."
  def my_tenant(%Scope{kind: :tenant, tenant_id: id} = scope),
    do: Scope.run(scope, fn -> Tenant |> Repo.get!(id) |> Repo.preload(:plan) end)

  @doc "The signed-in account's sessions, read in its scope."
  def list_my_sessions(%Scope{account: account} = scope),
    do: Scope.run(scope, fn -> QPBX.Core.Sessions.list(account) end)

  ## SIP credentials (see QPBX.Core.SipCredentials)

  defdelegate list_sip_credentials(scope), to: QPBX.Core.SipCredentials, as: :list

  defdelegate create_sip_credential(scope, attrs, actor),
    to: QPBX.Core.SipCredentials,
    as: :create

  defdelegate reset_sip_password(scope, id, actor),
    to: QPBX.Core.SipCredentials,
    as: :reset_password

  defdelegate delete_sip_credential(scope, id, actor), to: QPBX.Core.SipCredentials, as: :delete

  ## Tenant scope

  @doc """
  Runs `fun` in a transaction with `app.tenant_id` set, so row-level security hides every
  other tenant's rows even if a query forgets its tenant filter.
  """
  def with_tenant(tenant_id, fun) when is_binary(tenant_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT set_config('app.tenant_id', $1, true)", [Ecto.UUID.cast!(tenant_id)])

      case fun.() do
        # A failed write (e.g. a unique constraint) aborts the transaction: roll back, which
        # also discards the setting, and hand the error back.
        {:error, _} = error ->
          Repo.rollback(error)

        result ->
          # Clear it again: inside an outer transaction (tests) SET LOCAL would outlive this
          # call. On an exception the rollback discards the setting anyway.
          Repo.query!("SELECT set_config('app.tenant_id', '', true)")
          result
      end
    end)
  end

  defp save(op, changeset, action, actor) do
    Multi.new()
    |> then(&apply(Multi, op, [&1, :record, changeset]))
    |> Audit.add(actor, action, :record, changeset)
    |> Audit.commit(:record)
  end
end
