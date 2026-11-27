# Firewall (`QPBX.Firewall`)

**Purpose:** platform and tenant allow/block lists, stored in Postgres (the source of truth)
and applied to named nftables sets through the `qpbx-fwd` helper (`fwd/`). Kamailio reads the
SIP allow entries through a view (below).

**Public API** (`QPBX.Firewall`; exported `Entry`, `Sync`):
- `list_entries/1` (`level:`, `tenant_id:`), `get_entry!/1`, `change_entry/1`
- `create_entry(attrs, actor)`: audited; broadcasts `FirewallChanged`
- `delete_entry(entry, actor)`: audited; `{:error, :last_management_entry}` when it would
  remove the last non-expiring management entry
- `allowlisted?(ip_tuple, scope)`: on the platform allowlist for that scope (or "all")
- `sync_now/0`, `sync_status/0` (`%{at, errors, skipped}`), `helper_sets_flag/0`

**Entries:** level `platform` (any kind and scope) or `tenant` (allow + scope `sip` only,
prefix at most /24 for IPv4 or /48 for IPv6). Scope `ssh | sip | https | all`. Optional
`expires_at`, required `reason`, author recorded. Management entry = platform allow with scope
`ssh` or `all`.

**Sets:** `<kind>_<scope>_<v4|v6>`: 12 sets, listed by `QPBX.Firewall.Sets.all/0`. Scope
`all` fills the ssh, sip and https sets. Meaning comes from the base ruleset (Ansible
`nftables` role): SSH accepted only from `allow_ssh_*`; SIP/HTTPS `allow_*` accepted before
`block_*` dropped (the allowlist wins).

**Sync (`QPBX.Firewall.Sync`, one per node):** on every `FirewallChanged` event (cluster-wide
PubSub) and every 60 s, replaces all 12 sets with the database's active entries. Expired
entries drop out at the next run. If no management entry exists, the SSH allow sets are left
untouched (lockout guard). Database errors are logged and retried next tick.

**Events emitted:** `QPBX.Events.FirewallChanged` (v1). **Consumed:** the same event.
**Telemetry:** `[:qpbx, :firewall, :sync]` with `duration` and `errors`.

**Config:** `config :qpbx, QPBX.Firewall, helper: Helper.Socket | Helper.Noop | fake,
socket: path, reconcile_interval: ms, reconcile_on_start: bool`.

**Kamailio:** SIP allow entries (scope `sip` or `all`, not expired) are also a view,
`kamailio.address`, for Kamailio's permissions module (group 1 platform, group 2 tenant
office IPs); `QPBX.Edge` reloads it on `FirewallChanged` and every minute.

**Gotchas:** the app never runs `nft`. Seed management IPs on install with
`QPBX.Release.seed_management_ips/1`. Tests that create entries must wait for
`Sync.status/0` before ending (the Sync process shares the sandbox).
