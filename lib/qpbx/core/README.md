# Core (`QPBX.Core`)

**Purpose:** tenants, plans, limits, users, roles, audit log, and the telephony configuration
(extensions, devices, trunks, DIDs, routes, number rules and classes).

**Public API** (`QPBX.Core`; exported schemas `Plan`, `Tenant`, `PlatformAdmin`, `User`, `AuditLog`,
`SipCredential`, `Extension`, `Device`, `Trunk`, `TrunkAddress`, `Did`, `OutboundRoute`,
`EmergencyRoute`, `NumberRule`, `NumberClass`; `Vault`, `Scope`, `KeyProvider`; and `Numbers`).
Every changing function takes an `actor` (`%PlatformAdmin{}`, `%User{}` or `{:system, name}`)
and writes an audit entry in the same transaction.
- A tenant's users (tenant scope, for tenant admins; `QPBX.Core.Users`): `list_tenant_users/1`,
  `invite_user/3` (role, optional `extension_id`; the caller sends the setup link),
  `set_user_extension/4` (one user per extension: it moves from whoever had it),
  `set_user_role/4`, `delete_user/3` (ends their sessions); the last tenant admin cannot be
  demoted or removed, nobody removes themselves. For the signed-in tenant user:
  `my_extension/1`, `update_my_extension/3` (call features only: DND, call waiting,
  forwarding, ring time, follow-me). `users.extension_id` is cleared when the extension goes.
- Accounts for the portal: `list_platform_admins/0`, `issue_setup_link/2` (audited token; the
  CLI's `setup_link` uses it too), `account_emails/2` (names for the audit log; with a tenant
  id only its users), `list_my_audit_logs/2` (a tenant's own, under row-level security),
  `user_setup_link/3` and `sign_out_user/3` (a tenant admin, own users only).
- Plans: `list_plans/0`, `get_plan!/1`, `change_plan/2`, `create_plan/2`, `update_plan/3`
  (announces `ConfigChanged` "plans", so call control uses the new limits at once).
- Tenants: `list_tenants/0`, `get_tenant!/1`, `change_tenant/2`, `create_tenant/2`, `update_tenant/3`,
  `create_tenant_with_admin/3` (tenant and first tenant admin in one transaction).
- Accounts: `create_platform_admin/2`, `create_user/4` (role `tenant_admin` | `tenant_user`),
  `get_platform_admin/1`, `get_user/1`, `find_account_by_email/1`, `list_users/1`, `authenticate_platform_admin/2`,
  `authenticate_user/2`, `change_user/1`, `change_platform_admin/1`, `change_password/2`.
- Setup links: `setup_token/1`, `account_from_setup_token/1`, `complete_setup/2`.
- TOTP: `new_totp_secret/0`, `totp_uri/2`, `totp_enabled?/1`, `requires_totp?/1` (platform and tenant admins always), `totp_optional?/1`,
  `enable_totp/3`, `verify_totp/2`.
- Sessions: `create_session/2`, `fetch_session/2` (`touch: false` for checks that are not
  activity), `list_sessions/1`, `revoke_session/3`, `revoke_sessions/3` (`except:`),
  `end_session/1`, `session_idle_timeout/0`. Password and 2FA changes revoke all sessions.
  `QPBX.Core.SessionSweeper` ends idle/expired sessions every 30 s.
- Login limits: `login_check/1`, `login_failed/2` (IP, optional account), `login_succeeded/1`
  (`QPBX.Core.LoginGuard`; never locks accounts).
- Audit: `audit/4` (for changes made by other areas), `list_audit_logs/1`.
- SIP credentials: `list_sip_credentials/1`, `create_sip_credential/3` (returns the password
  once), `reset_sip_password/3`, `delete_sip_credential/3` (tenant scope); each announces
  `SipCredentialsChanged`. Tenant creation and updates announce `TenantsChanged` (after commit).
- Extensions (tenant scope): `list_extensions/1`, `get_extension!/2`, `change_extension/2`,
  `create_extension/3` (checks `max_extensions` under a lock on the tenant row),
  `update_extension/4`, `delete_extension/3` (removes its devices and their SIP logins).
- Devices: `change_device/1`, `add_device/4` (own SIP login `<extension>-<label>`, or the
  extension number itself when the label is empty (one such device per extension); returns the
  password once), `delete_device/3`, `reset_device_password/3`.
- Trunks (platform scope: shared carriers; tenant scope: its own): `list_trunks/1`,
  `trunk_choices/1` (own and platform trunks for a tenant's routes), `get_trunk!/2`,
  `change_trunk/2`, `create_trunk/3`, `update_trunk/4`, `delete_trunk/3`,
  `registration_trunks/0` (all tenants, decrypted password: for `QPBX.Edge` only); each trunk
  has a database-generated `edge_id` (Kamailio's dispatcher set). Delete is refused while a
  route or emergency route uses it. Addresses are nested (`addresses: [...]`); an address of
  an IP-authenticated trunk may belong to one IP trunk only, across tenants. Passwords are
  encrypted.
- DIDs: platform `create_did/3`, `update_did/4` (moving tenants clears the destination; backup
  numbers move along), `delete_did/3`; tenant `set_did_destination/4` (own extension or an
  external number; not on backup numbers); `list_dids/1`, `get_did!/2`, `change_did/2`,
  `change_did_destination/2`.
- Outbound routes (tenant scope): `list_routes/1`, `get_route!/2`, `change_route/2`,
  `create_route/3`, `update_route/4`, `delete_route/3`; `trunk_ids` is the failover order.
- Numbering: `number_rule/1` (tenant override, else platform default, else Israel),
  `change_number_rule/2`, `put_number_rule/3`, `reset_number_rule/2`, `to_e164/2`; platform
  `list_number_classes/0`, `change_number_class/1`, `create_number_class/3`,
  `delete_number_class/3` (high-cost prefixes are class `premium`), `list_emergency_routes/0`,
  `change_emergency_route/1`, `create_emergency_route/3` (platform trunk only),
  `delete_emergency_route/3`.
- Call control snapshots (internal, for `QPBX.Telephony` only): `telephony_tenant/1`,
  `telephony_platform/0`, `telephony_dids/0`, `extension_addresses/1` (`{id, number,
  sip_domain}`).
- `QPBX.Core.Numbers` (pure): `to_e164/2`, `display/2`, `classify/3`, `select_route/2`,
  `carrier_number/2`.
- `with_tenant/2`: run a function with row-level security scoped to one tenant; a function
  returning `{:error, _}` rolls the transaction back and gets its error back.
- Scopes: `scope_for/1` (`QPBX.Core.Scope`: `:platform` or `:tenant`); scoped reads
  `list_users/1` (tenant scope) or `list_users/2` (platform scope and a tenant), `my_tenant/1`,
  `list_my_sessions/1`.
- `effective_limits/1`: plan limits merged with the tenant's overrides; nil = unlimited. Plan
  limits include `max_concurrent_calls_per_extension` and the outbound minute caps per
  destination class and period (`minutes_<class>_per_<hour|day|month>`,
  `Plan.class_minutes_limit/2`), used by call admission.
- `locales/0`: language codes offered by the installation (`config :qpbx, :locales`).
- `sip_base_domain/0`: tenant SIP domains are `<slug>.<base>` (`QPBX_SIP_BASE_DOMAIN` in prod).

**Events emitted:** `QPBX.Events.SessionsRevoked` (whenever sessions end),
`SipCredentialsChanged`, `TenantsChanged`, `ConfigChanged` (every telephony configuration
write, after its commit). **Events consumed:** none.

**Keys:** `QPBX.Core.KeyProvider` (`master_key/0`, `wrap/2`); the vault loads its key at start-up.

**Gotchas:**
- New tenant tables get `QPBX.Repo.RLS.enable/1` in their migration, and every tenant-facing
  function takes a `Scope` and runs through `Scope.run/2` (keep the explicit tenant filter too).
- The DB user must not be a superuser, or RLS is silently bypassed. In production the app's
  role has no schema rights and cannot change `audit_logs` rows; migrations run as `qpbx_owner`.
- `Scope.run/2` runs in a transaction for both scope kinds; `{:error, _}` from the function
  rolls back. Platform rows (`tenant_id` NULL: shared trunks, unassigned DIDs, the default
  number rule) are invisible inside a tenant scope, so reads of them happen outside it.
- Audit entries drop `password`, `hashed_password`, `totp_secret`, `ha1` and `push_token`; add new secret fields to
  `@secret_fields` in `audit.ex`.
- Plan limit names are `QPBX.Core.Plan.limits/0`; overrides are validated against it. every non-platform table carries `tenant_id`; queries are tenant-scoped.
