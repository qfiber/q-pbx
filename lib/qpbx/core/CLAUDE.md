# Core (`QPBX.Core`)

**Purpose:** tenants, plans, limits, users, roles, audit log. Later: extensions and routing objects.

**Public API:** none yet. Callers use only `QPBX.Core` functions.

**Events emitted:** none yet. **Events consumed:** none.

**Gotchas:** every non-platform table carries `tenant_id`; queries are tenant-scoped.
