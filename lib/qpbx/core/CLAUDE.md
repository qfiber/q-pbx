# Core (`QPBX.Core`)

**Purpose:** tenants, plans, limits, users, roles, audit log. Later: extensions and routing objects.

**Public API** (`QPBX.Core`; exported `Plan`, `Tenant`, `PlatformAdmin`, `User`, `AuditLog`, `Vault`).
Every changing function takes an `actor` (`%PlatformAdmin{}`, `%User{}` or `{:system, name}`)
and writes an audit entry in the same transaction.
- Plans: `list_plans/0`, `get_plan!/1`, `change_plan/2`, `create_plan/2`, `update_plan/3`.
- Tenants: `list_tenants/0`, `get_tenant!/1`, `change_tenant/2`, `create_tenant/2`, `update_tenant/3`.
- Accounts: `create_platform_admin/2`, `create_user/4` (role `tenant_admin` | `tenant_user`),
  `get_platform_admin/1`, `get_user/1`, `list_users/1`, `authenticate_platform_admin/2`,
  `authenticate_user/2`, `change_user/1`, `change_platform_admin/1`, `change_password/2`.
- Setup links: `setup_token/1`, `account_from_setup_token/1`, `complete_setup/2`.
- TOTP: `new_totp_secret/0`, `totp_uri/2`, `totp_enabled?/1`, `requires_totp?/1`,
  `enable_totp/3`, `verify_totp/2`.
- Audit: `audit/4` (for changes made by other areas), `list_audit_logs/1`.
- `with_tenant/2`: run a function with row-level security scoped to one tenant.
- `effective_limits/1`: plan limits merged with the tenant's overrides; nil = unlimited.
- `sip_base_domain/0`: tenant SIP domains are `<slug>.<base>` (`QPBX_SIP_BASE_DOMAIN` in prod).

**Events emitted:** none yet. **Events consumed:** none.

**Gotchas:**
- New tenant tables get `QPBX.Repo.RLS.enable/1` in their migration.
- The DB user must not be a superuser, or RLS is silently bypassed.
- Audit entries drop `password`, `hashed_password` and `totp_secret`; add new secret fields to
  `@secret_fields` in `audit.ex`.
- Plan limit names are `QPBX.Core.Plan.limits/0`; overrides are validated against it. every non-platform table carries `tenant_id`; queries are tenant-scoped.
