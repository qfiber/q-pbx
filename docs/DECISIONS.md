# Decision log

Newest first. Each entry: date, what, why, alternatives rejected.

## 2026-11-27: The Kamailio edge (2-3)

- **Registration trunk passwords reach Kamailio over JSON-RPC (`uac.reg_add`), not a view.**
  They are encrypted in the database and the key is not in it; the app pushes and reconciles
  every minute, which also covers a Kamailio restart. Rejected: storing HA1 for carriers (the
  carrier's realm is not always known in advance).
- **Registration trunks are identified by the R-URI user** (Kamailio registers as the trunk's
  UUID, which is unguessable); **IP trunks by source address** in the dispatcher, which holds
  IP trunks only. A shared host made the first-match source lookup ambiguous.
- **Outbound failover across a trunk's addresses happens in Kamailio** (priority order, 4 s
  per address, OPTIONS pings); failover between carriers stays with call control (2-5).
- **No in-dialog relaying:** requests from outside may only go to FreeSWITCH, because every
  call is bridged there.
- **FreeSWITCH reaches phones through Kamailio** with `sip_route_uri`; trunks by naming the
  trunk's edge id in a header Kamailio removes.
- **SNI from a generated `tls.cfg`** (one profile per tenant certificate directory), rewritten
  after each certificate change; acme.sh signals tenant issues and renewals by touching
  `tenants/.updated`.

## 2026-11-27: Telephony data model (2-2)

- **One SIP login per device** (`<extension>-<label>`), not per extension: a lost phone is cut
  off alone, and the extension rings all its devices.
- **Platform trunks are the carriers;** no separate `carriers` table, which would hold only a
  name. Tenant trunks are bring-your-own-carrier.
- **An IP trunk's address belongs to one IP trunk across all tenants,** because Kamailio
  finds the trunk (and tenant) of an incoming call by its source address. Registration trunks
  may share a host (two tenants on the same carrier).
- **Trunk passwords are encrypted with Cloak** (Kamailio needs them in clear to register;
  they will reach it over JSON-RPC, not through a database view).
- **DID destinations are `destination_type` with `destination_id`,** plus `destination_number`
  for an external number. Phase 2 has extension and external; more types come with their
  features.
- **Number rules: platform default, tenant override, Israel built in** when neither exists.
  Country-specific short forms (Israeli 1-800, star numbers) are not handled yet.
- **Every telephony write announces `ConfigChanged` after its commit;** call control (2-5)
  drops its cache on it.

## 2026-11-27: How Kamailio reads credentials (2-1)

- **Read-only views shaped for Kamailio's htable,** loaded into memory and reloaded on change
  over JSON-RPC (`QPBX.Edge`), as the spec's "keeps routing data in shared memory" asks.
  Kamailio keeps working from memory while PostgreSQL is down. Rejected: `auth_db` (a
  database query per request).
- **Only HA1 is stored,** never the password. HA1 is MD5 because SIP digest and the phones
  require it, and it is password-equivalent for its realm, so only Kamailio's role reads it.
  SHA-256 digest (RFC 8760) can be added later for clients that support it.
- **The digest realm is the tenant's SIP domain;** tenant slugs are therefore fixed after
  creation.
- **The `kamailio` role in the playbook now runs after the app,** whose migrations create
  the views Kamailio loads at start-up.

## 2026-11-27: The busy-lamp trial in two steps (2-0)

- **2-0a first:** Kamailio's presence server, with states published as JSON through
  `pua_json` (by a script standing in for Elixir), checked with scripted subscribers for the
  dialog, presence and message-summary packages. **2-0b once calls work:** Meow's own live
  engine test, which needs a real call between two extensions to see ringing and on-call lamps.
  Why: the Meow proof needs call control (2-5); the publishing design should not wait for it.
- **Elixir publishes through `pua_json`** (JSON over Kamailio's local JSON-RPC), so Q-PBX needs
  no SIP stack of its own to drive lamps. To confirm in 2-0a.

## 2026-11-27: Invoicing later; busy-lamp trial with Meow

- **Billing and invoicing becomes phase 11** (after 1.0): rates, charges per client from CDRs
  (DIDs held, external minutes), automatic detailed invoices by email. Its spec is written and
  approved before it starts. Version 1 stays without billing, as the spec says.
- **No Grandstream phone is available now:** the phase 2 busy-lamp and voicemail-light trial
  uses Meow (desktop build from qFiber's Meow repository, on a throwaway profile) plus a
  scripted SIP client as the other party. The Grandstream check is repeated once a phone is
  available; until then that part of phase 2's Done-when stays open.

## 2026-11-27: Phase 2 setup

- **Lab testing:** the team registers a real Grandstream phone and Meow to the lab and makes the
  test calls; carriers are simulated in the lab (two test carriers standing in for Partner
  and Cellcom); a real carrier is tested later on a public server.
- **Kamailio 6.0** from the Kamailio project's signed Debian repository. Rejected: Debian's
  5.6 (no longer maintained upstream).
- **Voicemail is encrypted from phase 2:** the storage layer gets per-file envelope encryption
  now, and recordings and faxes reuse it in phase 4 (moves part of security item S10 earlier).
- **Backups in the lab go to a second VM;** the timed restore runs onto a third, fresh VM.

## 2026-11-27: Certificates without root (1b-8)

- **acme.sh runs as `qpbx-acme`;** reloading nginx and Kamailio, which needs root, moved to a
  root-owned systemd path unit that watches the certificate files. Rejected: a sudo rule for
  the reload (a wider door), or keeping acme.sh as root.
- **Tenant certificate renewals inside `tenants/` are not watched yet:** Kamailio does not
  serve them until phase 2, which adds a watch per tenant certificate.

## 2026-11-27: Master key in AWS KMS (1b-6)

- **The same master key is wrapped by KMS** (Encrypt), not replaced by a new KMS data key, so
  switching needs no re-encryption of stored data and can be reversed with the backed-up key.
- **AWS credentials sit in the server's environment file.** A thief of the server can still
  ask KMS for the key while the credentials are valid, but every unwrap is logged in AWS and
  access can be revoked there; the plain key is never on disk. On AWS machines, an instance
  role would remove the stored credentials (later, if Q-PBX runs on AWS).
- **The switch removes the plain key from the server only after the app has started with
  KMS, and only when the operator confirms an off-server backup** (`qpbx_kms_key_backed_up`).

## 2026-11-27: Login protection details (1b-3)

- **Blocks are per client IP only;** accounts are never locked, so nobody can lock an
  admin out on purpose. Platform-allowlisted IPs are exempt from blocks and checks.
- **The human check fails open on an outside service's outage** (network error or 5xx), as
  Friendly Captcha's documentation advises; per-IP limits still apply. A 4xx (wrong key) fails
  closed so a misconfiguration is noticed.
- **Built-in proof of work uses the ALTCHA format** (public, documented), so the open-source
  ALTCHA widget could replace our small solver later. Used challenges are remembered per node
  (ETS); a shared store comes with the second app node (phase 9).

## 2026-11-27: Fraud caps without rating

- Phase 2 caps minutes per destination class per hour, day and month, and treats a
  platform-managed list of high-cost prefixes as premium (blocked unless allowed). Why: real
  money caps need a per-prefix rate table, close to the rating the spec excludes; class caps
  plus the high-cost list stop toll fraud without it. Rejected for now: money-based caps.

## 2026-11-27: Visual call-flow editor in 1.0

- Phase 4 adds a drag-and-drop editor for each DID's routing (time conditions, IVRs, ring
  groups, voicemail), built on the LiveView canvas that the phase 8 flow builder extends.
  Rejected: forms only until phase 8; a read-only diagram in 1.0.

## 2026-11-27: Trunks and carrier failover

- **Several signalling addresses per trunk** with OPTIONS health checks (Kamailio dispatcher),
  because carriers differ (Partner gives one IP, others two or four).
- **Outbound failover between carriers** is standard and is already in the spec's ordered
  trunk failover; added: per-trunk caller ID rules, because a carrier may refuse to present a
  number it does not hold.
- **Incoming failover between carriers** cannot be done by the PBX alone: only the carrier
  holding a number can deliver its calls. Q-PBX supports it by accepting backup (alias)
  numbers that route like the DID, for use with the carrier's "forward on unreachable".

## 2026-11-27: Phase 1 review answers

- **FreeSWITCH modules confirmed, plus additions:** mod_opusfile and mod_shout (recordings as
  Opus or MP3, as the spec says), mod_bcg729 (G.729, optional in the spec; built from
  xadhoom/mod_bcg729 against Debian's libbcg729), mod_loopback (local routing and transfers)
  and mod_json_cdr (every call leg also spooled to disk as JSON, so no CDR is lost while
  Elixir is down; Elixir imports the spool in phase 2). Packages carry a build stamp.
- **nginx in front of the app** (reverses the P1-09 "app serves TLS itself" choice), so the
  operator can run ModSecurity. nginx terminates TLS, serves ACME challenges, and runs as
  `www-data` with only `CAP_NET_BIND_SERVICE` (no root master). The app listens on
  127.0.0.1:4000 and holds no capabilities. The real client IP comes from nginx
  (`X-Real-IP`, trusted from localhost only); behind a CDN, nginx trusts the CDN header only
  from the CDN's published ranges.
- **Tenant office IP limits confirmed:** at most /24 (IPv4) or /48 (IPv6).
- **Secrets file goes into the encrypted file backup** (phase 2), with the backup password
  kept off the server.
- **Login rate limits:** per client IP, 5 failed attempts block for 1 hour, 5 more for
  24 hours (phase 1b).
- **Languages are configuration:** one list in `config :qpbx, :locales`; each language has its
  own `.po` files, so adding one needs no code change.

## 2026-11-27: Security baseline

- **What:** the spec gains a "Security baseline" (database, login, TLS everywhere, sessions,
  encryption at rest, encrypted recordings, private temp data, least privilege). STATUS.md
  has the phased plan.
- **Changes to earlier decisions:**
  - Sessions move from signed cookies with a 12 h expiry (P1-04) to server-side sessions
    checked on every request: 15 min idle timeout, 12 h maximum, instant revocation.
  - 2FA becomes mandatory for tenant admins too, not only platform admins.
  - The Cloak key gets a key-provider behaviour (local file, AWS KMS) instead of only an
    environment variable.
- **Answers:** plain SIP on 5060 stays open for phones and trunks (carriers mostly
  use it), with TLS 5061 and SRTP as the default and in provisioning; AWS KMS is the first
  external key store; a built-in self-hosted proof of work is the default login challenge,
  next to Friendly Captcha, Turnstile and Captcha.eu; full-disk encryption is a later option.
- **Why now:** sessions, login protection, enforced row-level security and the database role
  split change code that phase 2 builds on, so they come before phase 2 ("phase 1b").
  Recording encryption and private media buffers come with recording (phase 4), and
  cross-server TLS with HA (phase 9).

## 2026-11-27: Certificates (P1-10)

- **acme.sh**, pinned by commit, runs as root from systemd timers (daily renewal, and every 5
  minutes for new tenant domains in per_host mode). Rejected: certbot (no broad DNS plugin
  set without extra packages per provider).
- **Reload without restart:** after every issue or renewal, the app clears Erlang's PEM cache
  over `bin/qpbx rpc`, and Kamailio reloads TLS over JSON-RPC. Calls and portal sessions stay up.
- **Wildcard certificate files use `*.<domain>` as the main name,** so wildcard and per_host
  certificates never share files in acme.sh's store.
- **Lab testing uses Pebble** (Let's Encrypt's test ACME server) with real HTTP-01 and DNS-01
  validation (`lab/acme/`); the lab-only DNS plugin never ships in the roles.

## 2026-11-27: Packaging and server layout (P1-09)

- **FreeSWITCH modules:** the spec's list (sofia, xml_curl, event_socket, spandsp, conference,
  callcenter, opus) plus the core modules FreeSWITCH cannot run calls without: mod_dptools
  (answer, park, bridge, playback), mod_commands (API commands), mod_dialplan_xml (static
  fallback), mod_sndfile, mod_native_file, mod_tone_stream, mod_local_stream, mod_say_en,
  mod_console and mod_logfile.
- **FreeSWITCH is built from public GitHub sources** (signalwire/freeswitch v1.10.12,
  freeswitch/sofia-sip v1.13.17, freeswitch/spandsp at commit 0d2e6ac, because newer spandsp
  breaks mod_spandsp in 1.10.12). No SignalWire token is needed for this.
- ~~The app terminates TLS itself on 443~~ Replaced by nginx in front (phase 1 review, above).
- **Secrets are generated on the server** (`/etc/qpbx/secrets.json`, root only) on first
  install and never leave it. It must be in the backups: losing the Cloak key makes TOTP
  secrets unreadable.
- **PostgreSQL 16 comes from the PostgreSQL project's apt repository** (Debian 12 ships 15).
- **Kamailio is Debian 12's 5.6 package** for phase 1; the version for phase 2 is chosen with
  its real config.
- **App package versions carry a build stamp** (`0.1.0+YYYYMMDDHHMMSS`), so every build upgrades.

## 2026-11-27: Dual-stack IPv4 and IPv6

- **What:** every client-facing part (SIP edge, RTP, portal, API, provisioning, firewall)
  supports IPv4 and IPv6; the service IP gets one address of each family. Spec updated.
- **Why:** IPv6 is common on mobile networks and some ISPs, and native IPv6 avoids NAT, which
  causes most SIP audio problems. Carriers are often IPv4-only, so trunks pick their family
  and FreeSWITCH bridges between the two.
- **Rejected:** IPv4 only (the spec did not mention IPv6).
- **Lab gap:** the local libvirt network is IPv4-only, so IPv6 is tested in containers and
  unit tests until a lab network with IPv6 exists.

## 2026-11-27: Developer documentation layout

- **What:** the developer guide is `docs/DEVELOPING.md`; each module documents its purpose,
  public API, events and gotchas in its own `README.md`; `docs/STATUS.md` and this log are
  updated in the same commit as the code. The spec section on tooling-specific project memory
  was removed.
- **Why:** the repository should read as a normal open source project; editor and tooling
  configuration stays on each developer's machine.

## 2026-11-27: Firewall design (P1-08)

- **Twelve named sets** `<allow|block>_<ssh|sip|https>_<v4|v6>`; scope `all` fills all three
  scopes. The allowlist wins through rule order in the base ruleset (allow accepted before
  block dropped). Rejected: one set per kind (cannot express scope).
- **Every sync replaces all sets in full** (atomic per set in `qpbx-fwd`), on each change and
  every 60 s. Simpler than diffs and it repairs drift. Expiry is handled by the next sync
  (within 60 s), not by nftables timeouts.
- **Lockout guard:** an empty database never empties the SSH allow sets; Ansible seeds the
  first management IPs into both the base ruleset and the database.
- **Tenant entries** are SIP allow only and at most /24 (IPv4) or /48 (IPv6), because they
  bypass SIP bans for everyone. The spec gives no width limit; this one is a safety default
  that is easy to change.
- **Tenant entries are allowed at the nftables level for all SIP traffic;** per-tenant
  meaning (only that tenant's domain) is applied by Kamailio in phase 2.

## 2026-11-27: License: AGPL-3.0 plus a contributor agreement

- **What:** Q-PBX stays AGPL-3.0, as the spec says. Outside contributors sign a CLA
  (`CLA.md`) that lets qFiber relicense their contributions, including under commercial terms.
  Copyright holder: qFiber.
- **Why:** the goal is free software that only qFiber can sell under closed, commercial terms.
  The AGPL alone does not stop others from selling or hosting it, but it forces them to publish
  their changes; the CLA keeps qFiber able to dual-license.
- **Rejected:** PolyForm Noncommercial and FSL-1.1 (source-available, not open source, against
  the spec's goal of an open source release).

## 2026-11-27: Accounts (P1-04)

- **Row-level security semantics:** inside `QPBX.Core.with_tenant/2`, `app.tenant_id` is set
  and only that tenant's rows are visible or writable. Outside it (platform admin screens,
  background jobs) the setting is empty and all rows are visible. This is the spec's "safety
  net": it catches a tenant-scoped request whose query forgot its filter. Rejected: denying all
  rows when unset, which would force every platform query through a bypass role.
- **Setup links are signed tokens** (`Plug.Crypto`, 48 h) carrying a fingerprint of the
  password hash, so a link works once and dies when the password is set. No token table.
- **Separate login pages** for platform admins and tenant users, since they are separate tables.
- **TOTP accepts the current and the previous 30 s window,** and never a code at or before the
  last accepted one.
- **TOTP secrets are encrypted with Cloak**, as the spec asks for secrets.
- **Every changing Core function takes an actor** and writes its audit entry in the same transaction.

## 2026-11-27: Plans, tenants and the database role (P1-03)

- **A nil plan limit means unlimited.** Tenant `limit_overrides` may set a limit to nil too.
- **Only minute caps for now** (per day and per month). Spend caps wait for an answer on rates
  (see STATUS.md, open questions). Rejected: guessing a rating model.
- **The app's database user is not a superuser** in every environment, because superusers
  bypass row-level security. Dev/test use role `qpbx`.
- **Time zones use the `tz` package** with bundled IANA data. Rejected: `tzdata`, which
  downloads updates at runtime, unwanted on a hardened server.

## 2026-11-27: Phase 1 clarifications

- **`qpbx-fwd` is written in Go.** Why: one small static binary that is easy to audit and
  ship as a `.deb`, kept outside the BEAM. Rejected: a second Elixir release (much larger
  for three commands), C (harder to keep its input parsing safe).
- **CI is GitHub Actions** on `qfiber/q-pbx`.
- **Two certificate modes** (spec updated): a wildcard through DNS-01 with any acme.sh DNS
  provider (Cloudflare by default), or one certificate per hostname through HTTP-01, including
  one per tenant SIP domain issued on tenant create. Why: not every operator uses Cloudflare
  or has a DNS API. Rejected: wildcard-only (the original spec).
- **Certificates get a ninth Ansible role, `certificates`,** using acme.sh. Why: the spec's
  eight roles named none, and the certificate is shared by Kamailio and the web server.
- **The phase 1 lab is a local Debian 12 VM** (libvirt) until real lab hardware is ready.
- **User model for 1.0:** each user belongs to one tenant; platform admins live in their own
  `platform_admins` table, as the data model lists. Rejected for now: users with roles in
  several tenants.
- **Reseller tier is scheduled as phase 10** (spec updated). It stays out of 1.0, as the spec's
  non-goals say. Its design is written and approved before that phase starts.
- **Setup links in phase 1:** a minimal SMTP mailer sends account setup links, and a CLI
  command prints them. The rest of the notification service stays in phase 3. Why: a tenant
  admin needs a way to set a password and 2FA before phase 3 exists.
- **FreeSWITCH is built as our own `.deb` in CI** with only the spec's modules, using the
  SignalWire token (a CI secret). Rejected: installing SignalWire's prebuilt packages at
  deploy time (the install would depend on their repository).

## 2026-11-26: Decisions locked in by the product spec

Source: `docs/SPEC.md`, "Decisions locked in". The spec does not record the alternatives
that were rejected, so they are not listed here.

| Area | Decision |
| --- | --- |
| Name / repo | Q-PBX (`qfiber/q-pbx`) |
| Deployment | Multi-tenant SaaS |
| Media engine | FreeSWITCH |
| SIP edge | Kamailio |
| Control plane | Elixir, Phoenix, LiveView, Oban; one Mix project with enforced module boundaries |
| Database | PostgreSQL |
| Hosting | qFiber's own servers and IP space; Debian 12, native install with Ansible |
| Reliability | Single server first, active/standby later |
| Scale target | Under 500 extensions in version 1, designed to grow |
| Portal languages | English and Arabic (full RTL) |
| First phone brand | Grandstream |
| Desktop and mobile app | Meow (existing qFiber product) |
| Push | A per-installation provider; qFiber uses its own push gateway and sells access to other operators |
| License | AGPL-3.0 |

Architecture choices the spec also fixes (same date, same source):

- One Mix project with the `boundary` library instead of an umbrella. Why: the isolation of an
  umbrella without eleven separate apps to maintain. Rejected: umbrella project.
- Kamailio authenticates all SIP; FreeSWITCH accepts SIP only from Kamailio; `mod_xml_curl`
  serves dialplan and configuration, not a user directory.
- One routing path: every call is parked and driven by an Elixir call process over the event
  socket. No feature is also written as XML dialplan.
- Registration-based carrier trunks are registered by Kamailio, so FreeSWITCH nodes hold no carrier state.
- The Elixir app runs without root; nftables changes go through the separate `qpbx-fwd` helper
  (three commands over a Unix socket, `CAP_NET_ADMIN` only).
- No Docker in production; Docker only for CI integration tests and a later demo.
