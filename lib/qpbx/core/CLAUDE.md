# Core (`QPBX.Core`)

**Purpose:** tenants, plans, limits, users, roles, audit log. Later: extensions and routing objects.

**Public API** (`QPBX.Core`; exported structs `Plan`, `Tenant`):
- Plans: `list_plans/0`, `get_plan!/1`, `change_plan/2`, `create_plan/1`, `update_plan/2`.
- Tenants: `list_tenants/0`, `get_tenant!/1`, `change_tenant/2`, `create_tenant/1`, `update_tenant/2`.
- `effective_limits/1`: plan limits merged with the tenant's overrides; nil = unlimited.
- `sip_base_domain/0`: tenant SIP domains are `<slug>.<base>` (`QPBX_SIP_BASE_DOMAIN` in prod).

**Events emitted:** none yet. **Events consumed:** none.

**Gotchas:** plan limit names are `QPBX.Core.Plan.limits/0`; overrides are validated against it. every non-platform table carries `tenant_id`; queries are tenant-scoped.
