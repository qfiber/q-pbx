# Decision log

Newest first. Each entry: date, what, why, alternatives rejected.

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
