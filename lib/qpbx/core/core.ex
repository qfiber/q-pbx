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
      SipCredential,
      Extension,
      Device,
      Trunk,
      TrunkAddress,
      Did,
      OutboundRoute,
      EmergencyRoute,
      NumberRule,
      NumberClass,
      Numbers,
      ApiKey,
      Encrypted.Binary
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

  @doc "Updates a plan; call control picks up the new limits of its tenants at once."
  def update_plan(%Plan{} = plan, attrs, actor) do
    save(:update, Plan.changeset(plan, attrs), "plan.update", actor)
    |> QPBX.Core.Changes.announce(nil, "plans")
  end

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
  defdelegate issue_setup_link(account, actor), to: Accounts
  defdelegate list_platform_admins(), to: Accounts
  defdelegate account_emails(ids, tenant_id \\ nil), to: Accounts
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

  ## A tenant's users (tenant admins; see QPBX.Core.Users)

  defdelegate list_tenant_users(scope), to: QPBX.Core.Users, as: :list
  defdelegate invite_user(scope, attrs, actor), to: QPBX.Core.Users, as: :invite

  defdelegate set_user_extension(scope, user_id, ext_id, actor),
    to: QPBX.Core.Users,
    as: :set_extension

  defdelegate set_user_role(scope, user_id, role, actor), to: QPBX.Core.Users, as: :set_role
  defdelegate delete_user(scope, user_id, actor), to: QPBX.Core.Users, as: :delete

  @doc "A tenant admin issues a new setup link for one of the tenant's users: `{:ok, user, token}`."
  defdelegate user_setup_link(scope, user_id, actor), to: QPBX.Core.Users, as: :setup_link

  @doc "A tenant admin ends every session of one of the tenant's users: `{:ok, count}`."
  defdelegate sign_out_user(scope, user_id, actor), to: QPBX.Core.Users, as: :sign_out

  @doc "The signed-in tenant user's own extension (with devices), or nil."
  defdelegate my_extension(scope), to: QPBX.Core.Users

  @doc "A tenant user changes their own extension's call features (forwarding, DND, follow-me)."
  defdelegate update_my_extension(scope, attrs, actor), to: QPBX.Core.Users

  ## API keys (see QPBX.Core.ApiKeys and QPBX.Core.Idempotency)

  defdelegate list_api_keys(scope), to: QPBX.Core.ApiKeys, as: :list
  defdelegate change_api_key(attrs \\ %{}), to: QPBX.Core.ApiKeys, as: :change

  @doc "Creates a key in the scope (tenant or platform): `{:ok, key, token}`, the token shown once."
  defdelegate create_api_key(scope, attrs, actor), to: QPBX.Core.ApiKeys, as: :create
  defdelegate revoke_api_key(scope, id, actor), to: QPBX.Core.ApiKeys, as: :revoke
  defdelegate authenticate_api_key(token), to: QPBX.Core.ApiKeys, as: :authenticate
  defdelegate api_rate_limit(key), to: QPBX.Core.ApiKeys, as: :rate_limit
  defdelegate idempotency_claim(key, idem_key, fingerprint), to: QPBX.Core.Idempotency, as: :claim

  defdelegate idempotency_finish(key, idem_key, status, body),
    to: QPBX.Core.Idempotency,
    as: :finish

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

  defdelegate login_failed(ip, account \\ nil, kind \\ :password),
    to: QPBX.Core.LoginGuard,
    as: :failure

  defdelegate login_succeeded(ip), to: QPBX.Core.LoginGuard, as: :success

  ## Audit log

  @doc "Records an audit entry for a change made outside `QPBX.Core` (for example the firewall)."
  def audit(actor, action, target, changes),
    do: actor |> Audit.entry(action, target, changes) |> Repo.insert()

  @doc """
  The tenant's own audit log, newest first (tenant admins; row-level security in force);
  `before: {inserted_at, id}` pages on from that entry.
  """
  def list_my_audit_logs(
        %QPBX.Core.Scope{kind: :tenant, tenant_id: tid} = scope,
        limit \\ 200,
        before \\ nil
      ) do
    QPBX.Core.Scope.run(scope, fn ->
      Repo.all(from a in audit_query(limit, before), where: a.tenant_id == ^tid)
    end)
  end

  @doc "Audit entries, newest first. Options: `limit`, `tenant_id`, `before: {inserted_at, id}`."
  def list_audit_logs(opts \\ []) do
    query = audit_query(Keyword.get(opts, :limit, 100), opts[:before])

    case Keyword.fetch(opts, :tenant_id) do
      {:ok, id} -> Repo.all(from a in query, where: a.tenant_id == ^id)
      :error -> Repo.all(query)
    end
  end

  # Keyset paging for the API: entries after `{inserted_at, id}`.
  defp audit_query(limit, before) do
    q = from a in AuditLog, order_by: [desc: a.inserted_at, desc: a.id], limit: ^limit

    case before do
      {at, id} ->
        where(
          q,
          [a],
          fragment("(?, ?) < (?, ?)", a.inserted_at, a.id, ^at, type(^id, :binary_id))
        )

      nil ->
        q
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

  ## Telephony configuration (every write announces ConfigChanged after its commit)

  alias QPBX.Core.{Dids, Extensions, Numbering, Routes, Trunks}

  defdelegate list_extensions(scope), to: Extensions, as: :list
  defdelegate get_extension!(scope, id), to: Extensions, as: :get!

  defdelegate change_extension(ext \\ %QPBX.Core.Extension{}, attrs \\ %{}),
    to: Extensions,
    as: :change

  defdelegate create_extension(scope, attrs, actor), to: Extensions, as: :create
  defdelegate update_extension(scope, ext, attrs, actor), to: Extensions, as: :update
  defdelegate delete_extension(scope, ext, actor), to: Extensions, as: :delete
  defdelegate change_device(attrs \\ %{}), to: Extensions
  defdelegate add_device(scope, ext, attrs, actor), to: Extensions
  defdelegate delete_device(scope, device_id, actor), to: Extensions
  defdelegate reset_device_password(scope, device_id, actor), to: Extensions

  defdelegate list_trunks(scope), to: Trunks, as: :list
  defdelegate trunk_choices(scope), to: Trunks, as: :choices
  defdelegate registration_trunks(), to: Trunks
  defdelegate get_trunk!(scope, id), to: Trunks, as: :get!

  defdelegate change_trunk(trunk \\ %QPBX.Core.Trunk{addresses: []}, attrs \\ %{}),
    to: Trunks,
    as: :change

  defdelegate create_trunk(scope, attrs, actor), to: Trunks, as: :create
  defdelegate update_trunk(scope, trunk, attrs, actor), to: Trunks, as: :update
  defdelegate delete_trunk(scope, trunk, actor), to: Trunks, as: :delete

  defdelegate list_dids(scope), to: Dids, as: :list
  defdelegate get_did!(scope, id), to: Dids, as: :get!
  defdelegate change_did(did \\ %QPBX.Core.Did{}, attrs \\ %{}), to: Dids, as: :change
  defdelegate change_did_destination(did, attrs \\ %{}), to: Dids, as: :change_destination
  defdelegate create_did(scope, attrs, actor), to: Dids, as: :create
  defdelegate update_did(scope, did, attrs, actor), to: Dids, as: :update
  defdelegate delete_did(scope, did, actor), to: Dids, as: :delete
  defdelegate set_did_destination(scope, did, attrs, actor), to: Dids, as: :set_destination

  defdelegate list_routes(scope), to: Routes, as: :list
  defdelegate get_route!(scope, id), to: Routes, as: :get!

  defdelegate change_route(route \\ %QPBX.Core.OutboundRoute{}, attrs \\ %{}),
    to: Routes,
    as: :change

  defdelegate create_route(scope, attrs, actor), to: Routes, as: :create
  defdelegate update_route(scope, route, attrs, actor), to: Routes, as: :update
  defdelegate delete_route(scope, route, actor), to: Routes, as: :delete

  defdelegate number_rule(scope), to: Numbering, as: :rule
  defdelegate change_number_rule(rule, attrs \\ %{}), to: Numbering, as: :change_rule
  defdelegate put_number_rule(scope, attrs, actor), to: Numbering, as: :put_rule
  defdelegate reset_number_rule(scope, actor), to: Numbering, as: :reset_rule
  defdelegate list_number_classes(), to: Numbering, as: :list_classes
  defdelegate change_number_class(attrs \\ %{}), to: Numbering, as: :change_class
  defdelegate create_number_class(scope, attrs, actor), to: Numbering, as: :create_class
  defdelegate delete_number_class(scope, id, actor), to: Numbering, as: :delete_class
  defdelegate list_emergency_routes(), to: Numbering, as: :list_emergency
  defdelegate change_emergency_route(attrs \\ %{}), to: Numbering, as: :change_emergency
  defdelegate create_emergency_route(scope, attrs, actor), to: Numbering, as: :create_emergency
  defdelegate delete_emergency_route(scope, id, actor), to: Numbering, as: :delete_emergency

  ## Call control snapshots (internal: QPBX.Telephony caches them)

  defdelegate telephony_tenant(tenant_id), to: QPBX.Core.TelephonySnapshot, as: :tenant
  defdelegate telephony_platform(), to: QPBX.Core.TelephonySnapshot, as: :platform
  defdelegate telephony_dids(), to: QPBX.Core.TelephonySnapshot, as: :dids

  defdelegate extension_addresses(tenant_id \\ nil),
    to: QPBX.Core.TelephonySnapshot

  @doc "The tenant user an extension belongs to (`users.extension_id`), or nil."
  def extension_user(ext_id) when is_binary(ext_id),
    do: Repo.one(from u in QPBX.Core.User, where: u.extension_id == ^ext_id)

  def extension_user(_), do: nil

  @doc "The id of the tenant with this SIP domain, or nil."
  def tenant_id_for_domain(domain) when is_binary(domain),
    do: Repo.one(from t in Tenant, where: t.sip_domain == ^String.downcase(domain), select: t.id)

  def tenant_id_for_domain(_), do: nil

  @doc "The usage thresholds in force for a tenant: its own, else its plan's."
  def usage_thresholds(%Tenant{usage_thresholds: t}) when is_list(t), do: t
  def usage_thresholds(%Tenant{} = tenant), do: Repo.preload(tenant, :plan).plan.usage_thresholds

  @doc "`%{tenant_id, extension_id, number}` of the extension at a SIP domain and number, or nil."
  defdelegate extension_at(domain, number), to: QPBX.Core.TelephonySnapshot

  @doc "What a user typed (local formats allowed) as E.164, with the scope's number rule."
  def to_e164(scope, input), do: QPBX.Core.Numbers.to_e164(input, number_rule(scope))

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
