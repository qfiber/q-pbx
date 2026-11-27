# Edge (`QPBX.Edge`)

**Purpose:** Kamailio integration. Kamailio is the only SIP entry point and keeps no
configuration of its own: it loads read-only views in the `kamailio` database schema into
memory (role `qpbx_kamailio`, nothing else readable) and this area tells it to reload when
something changes. Configuration: `ansible/roles/kamailio/templates/kamailio.cfg.j2`.

| Kamailio module | View | What |
| --- | --- | --- |
| htable `domains` | `kamailio.domains` | tenant SIP domain -> tenant id |
| htable `credentials` | `kamailio.credentials` | `user@domain` -> HA1 |
| htable `trunks` | `kamailio.trunks` | edge id -> `trunk id;tenant id;auth mode;registrar URI`, and `reg:<trunk id>` -> edge id |
| dispatcher | `kamailio.dispatcher` | IP trunks: set = trunk edge id, one destination per address |
| permissions | `kamailio.address` | SIP allow lists: group 1 platform, group 2 tenant office IPs (tag = tenant) |
| uac | `kamailio.uacreg` (always empty) | registration trunks: records pushed over JSON-RPC |
| htable `settings` | `kamailio.settings` | protection thresholds from the admin panel (`edge_settings`) |
| htable `ipban` | `kamailio.ipban` | stored bans with their expiry, loaded at Kamailio start (`edge_bans`) |

**Protection (2-4), in Kamailio:** for every request from outside, the platform SIP allowlist
skips all checks; banned addresses (`ipban`: `<ip>` or `<ip>|<port>`) are dropped silently;
scanner user agents and floods (requests per address in 2-second buckets) ban the whole
address; REGISTER and INVITE are limited
per address and port per minute (503 over the limit, a ban at three times); failed logins
(wrong password, unknown user, someone else's user) ban the address and port, and many of
them the whole address. Tenant office IPs skip flood detection, get three times the
per-phone failure limit, and are never banned as a whole: `edgealert` flags them instead.
Thresholds are set in the admin panel (Platform > SIP protection; `edge_settings`, one row)
and applied live. `QPBX.Edge.Bans` (every 5 s) stores every new ban in `edge_bans` (so a
restarted Kamailio loads it back, expiry included), carries whole-address bans to
`QPBX.Firewall.ban/4` (nftables, with a timeout), raises `EdgeAlert` for flagged office IPs,
and lifts Kamailio bans of addresses that turned out to be allowed. Counters stay in memory
(windows of 2 s to 15 min).

**Busy lamps, presence, voicemail lights (2-0b):** Kamailio's presence server (in memory)
answers phones' SUBSCRIBE for `dialog`, `presence` and `message-summary` (digest auth, own
tenant only) and their PUBLISH of their own presence. `QPBX.Edge.Presence` turns every
`CallState` into a `pua_json` dialog update (POST to Kamailio's localhost `/presence`), and
publishes "no messages" for every extension (until voicemail, 2-7) at start, on extension
changes, every 5 minutes, and at once when Kamailio restarted (its start time moved).

**Public API:** `get_settings/0`, `change_settings/2`, `update_settings/2` (audited, announces
`ConfigChanged` "edge_settings"), `list_bans/0`, `lift_ban/2` (Kamailio, database and the
automatic firewall block; audited); `rpc/2` (any Kamailio JSON-RPC method), `reload/1`
("credentials", "domains", "trunks", "settings"), `reload_trunks/0` (trunks htable and dispatcher), `reload_allowlist/0`;
`QPBX.Edge.Registrations` (`sync/0`, `record/1`); `QPBX.Edge.Reloader` and `QPBX.Edge.Bans`
(started by the application, not in tests: `config :qpbx, :edge_workers`).

**Events consumed:** `SipCredentialsChanged` (credentials), `TenantsChanged` (domains),
`ConfigChanged` kind "trunks" (trunks, dispatcher, registrations) and "edge_settings"
(settings), `FirewallChanged` (allow
lists). Every minute: allow lists (entries expire) and registrations (a restarted Kamailio
has none). `CallState` (busy lamps), `ConfigChanged` "extensions" (voicemail lights).
**Events emitted:** `EdgeAlert`.

**What Kamailio does with a new request:**
- From FreeSWITCH (127.0.0.1:5080): with `X-QPBX-Trunk-Edge: <edge id>` to that trunk (IP
  trunk: its addresses by priority, next address after 4 s or a 408/5xx; registration trunk:
  its registrar, answering 401/407 with the registration's credentials); else to the phone
  registered as the R-URI (`user@tenant-domain`).
- From a registration trunk's carrier: R-URI user = the trunk id Kamailio registered as.
- From an IP trunk's carrier: source address in the dispatcher.
- Else a phone: digest auth with the tenant domain as realm; the From user must be the
  authenticated user. REGISTER the same (To user).
- To FreeSWITCH it adds `X-QPBX-Source` (`device` or `trunk`), `X-QPBX-Tenant`,
  `X-QPBX-Auth-User` (devices) or `X-QPBX-Trunk` (trunk id). `X-QPBX-*` headers from outside
  are removed.

**Gotchas:**
- FreeSWITCH reaches phones with R-URI `user@tenant-domain` and `sip_route_uri=sip:127.0.0.1:5060`
  (`fs_path` does not work: sofia resolves the domain first), and trunks by sending to
  `127.0.0.1:5060` with `X-QPBX-Trunk-Edge`.
- In-dialog requests from outside may only go to FreeSWITCH (anti-relay rule).
- Kamailio `$var(...)` cannot hold "no value": test htable entries and headers directly.
- `$shtinc` does not create a missing key: set it to 0 first.
- A REGISTER replaces the login's older contacts (`save("location", "0x04")`): one login
  is one device, and a stale contact would be forked to, holding a busy or redirect from the
  real device until the stale branch times out.
- `ipban` is loaded from the database at start only (`db_expires`); never `htable.reload` it
  at run time, the view lags Kamailio by up to 5 s.
- nftables does not filter loopback, so the lab check reads the block sets
  (`lab/done-when/phase2-protect.py`).
- Reloads are rate-limited by Kamailio (one per 5 s per module); failures are retried 5
  times, 5 s apart.
- Trunk host names are resolved at reload and every 10 minutes; an address that does not
  resolve is skipped (the rest of the trunk still loads).
- Registration passwords leave the app only over the localhost JSON-RPC socket; they are in
  no database view.
- TLS: `/usr/local/sbin/qpbx-kamailio-tls` writes `tls.cfg` with one SNI profile per tenant
  certificate; it runs after every certificate change, then `tls.reload`.
- Lab check: `lab/done-when/phase2-edge.py <vm-ip> <host-ip>`.
