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

**Protection (2-4), in Kamailio:** for every request from outside, the platform SIP allowlist
skips all checks; banned addresses (`ipban`: `<ip>` or `<ip>|<port>`) are dropped silently;
scanner user agents and floods (pike) ban the whole address; REGISTER and INVITE are limited
per address and port per minute (503 over the limit, a ban at three times); failed logins
(wrong password, unknown user, someone else's user) ban the address and port, and many of
them the whole address. Tenant office IPs skip flood detection, get three times the
per-phone failure limit, and are never banned as a whole: `edgealert` flags them instead.
Thresholds are Ansible variables (`qpbx_edge_*`). `QPBX.Edge.Bans` (every 5 s) carries
whole-address bans to `QPBX.Firewall.ban/4` (nftables, with a timeout), raises `EdgeAlert`
for flagged office IPs, and lifts Kamailio bans of addresses that turned out to be allowed.

**Public API:** `rpc/2` (any Kamailio JSON-RPC method), `reload/1` ("credentials", "domains",
"trunks"), `reload_trunks/0` (trunks htable and dispatcher), `reload_allowlist/0`;
`QPBX.Edge.Registrations` (`sync/0`, `record/1`); `QPBX.Edge.Reloader` and `QPBX.Edge.Bans`
(started by the application, not in tests: `config :qpbx, :edge_workers`).

**Events consumed:** `SipCredentialsChanged` (credentials), `TenantsChanged` (domains),
`ConfigChanged` kind "trunks" (trunks, dispatcher, registrations), `FirewallChanged` (allow
lists). Every minute: allow lists (entries expire) and registrations (a restarted Kamailio
has none). **Events emitted:** `EdgeAlert`.

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
