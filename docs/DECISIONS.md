# Decision log

Newest first. Each entry: date, what, why, alternatives rejected.

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
- **The app terminates TLS itself on 443** (Bandit) with HTTP on 80 only for redirects and ACME
  challenges; the spec allowed "behind nginx or directly". Rejected: nginx (one more service).
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
