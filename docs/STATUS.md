# Status

**Current phase:** 1b — Security hardening (approved 2026-11-27; phase 1 done)
**Last updated:** 2026-11-27

## Phase 1 goal

From `docs/SPEC.md`, "Build phases", phase 1:

- One Mix project `qfiber/q-pbx` with boundary checks, CI building the FreeSWITCH and app
  packages, Ansible roles, single-server lab, wildcard certificate, health endpoint.
- Project memory files and the session hook; firewall module and helper.
- Tenants, plans, users, roles, 2FA, audit log, English and Arabic RTL portal shell.

**Done when:** a platform admin creates a tenant with a plan, a tenant admin logs in with 2FA
in either language, and an allowlist change reaches nftables through the helper.

## Task breakdown

Each task ends with tests passing and this file updated in the same commit.

| # | Task | Scope | Tests / proof |
| --- | --- | --- | --- |
| P1-01 | Repo and Mix project | `git init`; Phoenix app with LiveView, Ecto/Postgres, Oban; `boundary` configured; area folders `lib/qpbx/{core,events,firewall,notify,web}/` with `QPBX.<Area>` public API modules and a `README.md` each; `mix format`, Credo strict, Dialyzer; Commands section of `docs/DEVELOPING.md` filled in | A deliberate cross-boundary call fails `mix compile`; `mix test` green |
| P1-02 | Doc checks | CI script that flags a change to a module's public API module without a change to that module's `README.md` | Script tests (changed / unchanged cases) |
| P1-03 | Core: plans and tenants | `plans` (typed limit columns + JSONB `features`), `tenants` (`sip_domain`, `timezone`, `locale`, `plan_id`, `limit_overrides`); effective-limit resolution (plan + override); unique SIP domain under the platform base domain | Unit tests |
| P1-04 | Core: accounts, roles, audit log | `platform_admins`; `users` (one tenant each) with `user_roles` (tenant admin, tenant user); one-time setup links (minimal SMTP mailer in `QPBX.Notify` plus a CLI command); Postgres RLS safety net on tenant tables (moved here from P1-03: the first tenant-owned table is `users`), Argon2 hashing, session expiry, TOTP 2FA (required for platform admins), `audit_logs` written for every admin change | Unit tests: hashing, TOTP verify/replay, role checks, audit entry per change; RLS test proving a tenant-scoped query cannot see another tenant's rows |
| P1-05 | Portal shell (EN/AR RTL) | LiveView layout with `dir="rtl"` for Arabic, gettext `en` and `ar`, locale switch; login and 2FA pages; platform admin: create plan, create tenant with plan, create tenant admin; tenant admin: landing page and 2FA enrolment | LiveView tests for the full Done-when flow in both locales |
| P1-06 | Health endpoint | `GET /health` (200 `ok` / 503 `degraded`/`down`, no details); `GET /health/details` (token); checker runs every 10 s and caches. Phase 1 checks: PostgreSQL, disk space, Oban backlog, certificate expiry, FreeSWITCH event socket reachable, Kamailio JSON-RPC reachable. Trunk registrations report `not_configured` until phase 2 | Unit tests per check; endpoint tests for each status and for missing/bad token |
| P1-07 | `qpbx-fwd` helper | Separate Go service on a local Unix socket, three commands only (add to set, remove from set, replace set); validates every address and set name against an allowed list; cannot touch rules or chains; writes current nftables state to disk after each change; systemd unit with only `CAP_NET_ADMIN` | Tests for command parsing and validation (rejects bad addresses, unknown sets, extra commands); integration test against real nftables in a Debian 12 VM |
| P1-08 | Firewall module | `firewall_entries` (scope SSH/SIP/HTTPS/all, platform or tenant level, optional expiry, reason, author), audited; allowlist wins over auto-bans; removing the last management IP is refused; applies changes through the helper; PubSub broadcast to all nodes plus 60 s reconcile against the DB; expiry removal | Unit tests for rules; reconcile test with a fake helper; end-to-end test with the real helper |
| P1-09 | Ansible roles and playbook | Roles `kamailio`, `freeswitch`, `qpbx_app`, `postgres`, `storage`, `nftables`, `hardening`, `monitoring`; one `site.yml`; single-host inventory. Phase 1 depth: packages installed, systemd units with the spec's hardening, nftables default deny with named sets, PostgreSQL 16 on localhost, storage folder, unattended upgrades, AppArmor profiles in complain mode, `qpbx-fwd` installed. Kamailio and FreeSWITCH installed and running with minimal config (FreeSWITCH SIP on 127.0.0.1 only); real call config is phase 2 | `ansible-lint`; playbook run twice against a fresh Debian 12 VM with no changes on the second run |
| P1-10 | Certificates | Ansible role `certificates` with acme.sh, two modes: wildcard through DNS-01 (Cloudflare default, any acme.sh DNS provider) or per-hostname through HTTP-01 (portal, SIP name, provisioning, and each tenant domain on tenant create); reload hooks for the web server and Kamailio; expiry feeds the health check | Issuance against a local ACME test server (Pebble) in both modes; renewal hook dry run |
| P1-11 | CI | Format, Credo, Dialyzer, boundary, tests with a Postgres service; doc check from P1-02; build the app as a `mix release` `.deb` on Debian 12; build a FreeSWITCH `.deb` from source (SignalWire token as a CI secret) with only sofia, xml_curl, event_socket, spandsp, conference, callcenter, opus | CI green; both packages install on a fresh Debian 12 VM |
| P1-12 | Lab bring-up and Done-when | Run the playbook on the local Debian 12 VM lab (bridged to the host LAN; no IPv6 on that LAN yet) with the CI packages; run the three Done-when checks and record the results here honestly | Done-when results below |

Out of scope for phase 1, on purpose: the modules `telephony`, `edge`, `fax`, `storage`,
`integrations` and `provisioning` are created in the phase that first needs them,
not as empty stubs now. `notify` starts in phase 1 with only the setup-link mailer. Kamailio in-memory sync of firewall lists waits for phase 2, when
Kamailio gets its real config.

## Done

- Project docs created: `docs/DEVELOPING.md`, `docs/STATUS.md`, `docs/DECISIONS.md`, `CHANGELOG.md`.
- P1-01 Repo and Mix project: Phoenix 1.8 app (`QPBX`, binary ids), Oban (queue `notify`),
  areas `core`, `events`, `firewall`, `notify`, `web` with boundaries; public API modules live
  inside their folders (`lib/qpbx/core/core.ex`). `QPBX.Repo` is its own boundary. Credo
  strict and Dialyzer pass. `scripts/check_boundary_enforced.sh` proves a forbidden reference
  fails the build. AGPL-3.0 `LICENSE` added.
- P1-02 Doc checks: `scripts/check_module_docs.sh <base>` fails when
  `lib/qpbx/<area>/<area>.ex` changed without `lib/qpbx/<area>/README.md`. Tests:
  `scripts/test/module_docs_test.sh`.
- P1-03 Core: plans and tenants. `plans` with typed limit columns (nil = unlimited),
  allowed destination classes and a `features` map; `tenants` with slug, `sip_domain`
  (`<slug>.<sip_base_domain>`), IANA time zone (bundled `tz` data), locale (`en`/`ar`), plan
  and `limit_overrides`; `QPBX.Core.effective_limits/1`. Dev/test DB user is the non-superuser
  `qpbx`. 9 tests.
- P1-04 Core: accounts, roles, audit log (core part). `platform_admins`; `users` (one tenant
  each, email unique across tenants, citext) with `user_roles` (`tenant_admin`,
  `tenant_user`); Argon2 passwords (12 to 256 chars, constant-time miss); signed setup tokens
  valid 48 h that stop working once the password changes; TOTP via NimbleTOTP with
  replay protection and one window of clock drift, secret encrypted with Cloak
  (`QPBX.Core.Vault`, key `QPBX_CLOAK_KEY`); `audit_logs` written in the same transaction as
  every change, never containing passwords or secrets; RLS (`QPBX.Repo.RLS`) on `users`,
  `user_roles`, `audit_logs` with `QPBX.Core.with_tenant/2`. 11 tests.
- P1-04 remainder: setup-link email (`QPBX.Notify.deliver_setup_link/2`, Oban queue `notify`,
  English/Arabic RTL, SMTP via `QPBX_SMTP_*` in prod; completed jobs pruned after a day) and
  the release CLI `QPBX.Release` (`migrate/0`, `create_platform_admin/2`, `setup_link/1`).
- P1-05 Portal shell: English and Arabic (`dir="rtl"`) with a language switch kept across
  login; separate logins `/platform/login` and `/login`; two-step login with TOTP; setup link
  page then 2FA enrolment (mandatory for platform admins, skippable for tenant users);
  12-hour sessions; platform pages for plans and for creating a tenant together with its first
  tenant admin in one transaction (the setup link is shown once and emailed); tenant landing
  page. Tests cover the whole Done-when portal flow in both languages, plus wrong password,
  wrong code, enrol-or-no-session, role separation, expiry, one-time links and the
  open-redirect guard. 39 tests in total.
- P1-06 Health endpoint: `QPBX.Web.Health` runs checks every 10 s (each in its own task,
  3 s timeout) and caches in ETS. `GET /health` returns 200 `ok` or 503 `degraded`/`down`
  with no details; `GET /health/details` needs `Authorization: Bearer $QPBX_HEALTH_TOKEN`
  (16+ chars). Checks: PostgreSQL, disk free %, Oban backlog, certificate expiry (warn under
  14 days), FreeSWITCH event socket (TCP connect; ESL login in phase 2), Kamailio JSON-RPC
  `core.version`, trunk registrations (`not_configured` until phase 2). `down` = a critical
  component (PostgreSQL, FreeSWITCH, Kamailio) in error. 10 new tests; smoke-tested on a dev
  server.
- P1-07 `qpbx-fwd` helper (Go, stdlib only) in `fwd/`: see `fwd/README.md`. Unit tests for
  parsing, validation (injection attempts, wrong family, zones, unknown ops/sets/fields,
  size limit), script generation, save/restore and tampered state; integration test against
  real nftables in a Debian 12 container (replace/add/remove, refusals leave rules unchanged,
  state restored after a simulated reboot): passing.
- P1-08 Firewall module: `firewall_entries` (RLS, audited, unique per level/tenant/kind/
  scope/cidr), 12 named sets, cluster-wide `FirewallChanged` event plus 60 s reconcile, expiry,
  last-management-IP protection with row locks, lockout guard, tenant entries limited to SIP
  allow and narrow prefixes; helper client over the Unix socket; platform page
  `/platform/firewall` (EN/AR); `QPBX.Release.seed_management_ips/1`. 23 new tests (62 in total).
- Fix: row-level security policies could fail with "invalid input syntax for type uuid" on a
  connection that had earlier run a tenant-scoped transaction (Postgres may evaluate both sides
  of `OR`, and the leftover setting is `''`). Policies now use `NULLIF` before the cast
  (migration `fix_rls_policy_cast`); regression check added. Found by repeated test runs.
- Docs renamed for the open source repo: `docs/DEVELOPING.md` and a `README.md` per module.
- P1-09 Ansible roles and playbook (`ansible/`): `site.yml` with roles `hardening`, `nftables`,
  `postgres`, `storage`, `certificates` (self-signed mode only so far), `kamailio`,
  `freeswitch`, `qpbx_app`, `monitoring`. Packages built in Debian 12 containers
  (`packaging/`): FreeSWITCH 1.10.12 (sofia-sip 1.13.17, spandsp pinned, only the listed
  modules, dependencies derived from the linked libraries), the app release and `qpbx-fwd`.
  Lab VM script `lab/create-vm.sh` (Debian 12 cloud image, bridged to the host LAN).
  Verified on the lab VM: ansible-lint passes (production profile); a fresh install, then a
  second run with `changed=0`; all services active; `/health` `ok`; SIP OPTIONS answered `503`
  (phase 1 placeholder); management IP seeded into the database reaches nftables through
  `qpbx-fwd`; everything recovers after a reboot; AppArmor profiles for FreeSWITCH,
  Kamailio, the app and `qpbx-fwd` loaded in complain mode.
- P1-10 Certificates: `certificates` role with acme.sh (pinned commit, daily renewal timer).
  Modes: `wildcard` (DNS-01 with any acme.sh DNS plugin, Cloudflare `dns_cf` by default;
  credentials in `qpbx_acme_dns_env`), `per_host` (HTTP-01 served by the app from its ACME
  webroot; platform names in one certificate, plus one per tenant SIP domain issued by a
  5-minute timer), `selfsigned` (labs). A reload hook makes the app (`:ssl.clear_pem_cache`) and
  Kamailio (`tls.reload`) use new certificates without restarting. Tested in the lab against
  a local Pebble ACME server with real validation: per_host (4 platform names plus one tenant
  domain), wildcard through DNS-01, a forced renewal picked up live on 443 and 5061, second run
  `changed=0`. App: `/.well-known/acme-challenge/:token` (strict token check, 3 tests),
  `QPBX.Release.list_sip_domains/0`.
- P1-11 CI (GitHub Actions): `.github/workflows/ci.yml` (Elixir format, compile with warnings
  as errors, Credo strict, boundary proof, tests on Postgres 16 as a non-superuser, Dialyzer,
  module README check on PRs; Go fmt/vet/tests and the real-nftables integration test;
  ansible-lint) and `.github/workflows/packages.yml` (app and `qpbx-fwd` `.deb` on every push
  to main, FreeSWITCH `.deb` when its packaging changes, on tags or by hand; uploaded as
  artifacts). First runs: Packages, Go and Ansible jobs passed; the Elixir job failed only on
  Dialyzer in the test environment (a test fake), fixed.
- P1-12 Lab bring-up and Done-when: see results below. Fixed on the way: the release CLI
  could not sign setup links (`plug_crypto` not started), SMTP without a login was rejected
  (now allowed, with TLS still required whenever a login is used), and two AppArmor profiles
  were widened for what complain mode logged (`nft` reading `/etc/iproute2`, `df` in the app).

- License: AGPL-3.0 kept, `CLA.md` and `CONTRIBUTING.md`
  added, copyright notice in `README.md`. Code pushed to `github.com/qfiber/q-pbx` (public).

## In progress

- 1b-1 Server-side sessions.

## Next

- Review of phase 1 and answers to the open points in the phase 1 report.
- Phase 1b: security items marked "1b" in the security plan, before phase 2.
- Done after the phase 1 review: nginx in front (non-root, real client IP, optional
  ModSecurity), FreeSWITCH modules added (G.729, Opus/MP3 recording, loopback, CDR spool; all
  load in the lab), languages moved to one config list, firewall and plan forms now clear
  after a save (live validation added).

## Phase 1b task breakdown

Approved 2026-11-27. Covers every "1b" item in the security plan below. Blocks are per IP
only; accounts are never locked (they get a challenge and an alert instead).

| # | Task | Security plan |
| --- | --- | --- |
| 1b-1 | Server-side sessions: `user_sessions` table (token hash, account, IP, user agent, created, last seen); checked on every request and LiveView event; 15 min idle and 12 h maximum; a sweeper ends idle sessions and disconnects their live pages; revocation on password or 2FA change; "sign out everywhere" and a session list on an account page; idle warning in the browser; CLI `revoke_sessions` | S7, S8 |
| 1b-2 | 2FA mandatory for tenant admins (existing ones enrol at next login) | S4 |
| 1b-3 | Login protection: per-IP failure counter in the database (5 failures: blocked 1 h; 5 more: 24 h; HTTP 429) on login, 2FA and setup pages; IPs on the platform HTTPS/all allowlist are exempt; per-account failures raise an alert entry; `Captcha` behaviour with built-in proof of work (default), Friendly Captcha, Cloudflare Turnstile, Captcha.eu, none | S5 |
| 1b-4 | Row-level security in force: `QPBX.Core.Scope`; tenant-facing Core functions run in the tenant's scope; RLS on `tenants` and `user_sessions`; test that a tenant scope cannot read another tenant's rows even with a missing filter | S1 |
| 1b-5 | Database roles: `qpbx_owner` owns the schema and runs migrations; the app's `qpbx` role has data rights only; `audit_logs` insert/select only; `pg_hba` limited to scram on localhost | S2 |
| 1b-6 | `KeyProvider` for the Cloak master key: local file (default) or AWS KMS (key stored wrapped, unwrapped at start-up); CLI to wrap the current key with KMS without re-encrypting data | S9 |
| 1b-7 | Temporary data in memory: app `TMPDIR`/uploads in `/run/qpbx/tmp` (0700); nginx request and proxy buffers in `/run/nginx` instead of disk | S11 |
| 1b-8 | Least privilege: hardening drop-ins for Kamailio and PostgreSQL; acme.sh as its own user with a root-owned path unit doing the reloads; a lab check that only allowed processes run as root | S12 |
| 1b-9 | Sobelow security scan in CI | S3 |
| 1b-10 | Lab verification: Done-when checks plus revocation, idle timeout, rate limits, DB roles, root processes | — |

## Security plan

Requirements: `docs/SPEC.md`, "Security baseline". Audit of phase 1 on 2026-11-27 (code and the
lab server). "1b" = before phase 2 starts.

| # | Requirement | Today | Work to do | When |
| --- | --- | --- | --- | --- |
| S1 | Row-level security on every tenant request | Policies exist on `users`, `user_roles`, `audit_logs`, `firewall_entries`, but **no request path runs inside `with_tenant`, so they never filter anything** | Tenant-scoped requests (portal, later API and jobs) run their queries in a tenant scope; a test proves a tenant page cannot read another tenant's rows; RLS on every new tenant table | 1b |
| S2 | DB access: least privilege | App connects as non-superuser `qpbx` on localhost; it owns the schema | Separate owner role for migrations; runtime role with only data rights; `audit_logs` insert/select only (no update/delete); `pg_hba` scram on localhost only; Kamailio read-only role on a view (phase 2) | 1b (Kamailio role: 2) |
| S3 | Validation and sanitization | Changesets validate every input; Ecto parameterizes all queries; HEEx escapes output; the only raw HTML is the server-generated QR SVG; strict token checks on setup and ACME paths | Add a CI scan (Sobelow) for unsafe patterns; keep `raw/1` only for generated SVG | 1b |
| S4 | 2FA for admins | Mandatory for platform admins; optional for tenant admins | Make it mandatory for tenant admins (enrolment cannot be skipped) | 1b |
| S5 | Login brute-force protection, CAPTCHA, proof of work | Real client IP already correct (nginx `X-Real-IP`, CDN header only from CDN ranges); no limits yet | Per client IP on login, 2FA and setup pages: 5 failures block for 1 hour, 5 more for 24 hours (HTTP 429, counters survive restarts); per account: after 5 failures, always challenge and alert rather than lock (so nobody can lock an admin out on purpose); `Captcha` behaviour with a built-in self-hosted proof of work (default), Friendly Captcha, Cloudflare Turnstile, Captcha.eu and "none", configured per installation, on login, 2FA, setup and password pages; failed logins feed the brute-force alert (phase 3) | 1b |
| S6 | TLS everywhere | HTTPS with HSTS on 443 (TLS 1.2+); HTTP only redirects and serves ACME; SIP TLS on 5061 available; SMTP requires TLS when a login is used; localhost-only plain links (Postgres, event socket, Kamailio to FreeSWITCH, JSON-RPC) | SIP TLS 5061 with SRTP as the default and in provisioning; 5060 stays open for phones and trunks that need it (phase 2); HTTPS-only webhooks and CRM calls (phase 3); TLS or WireGuard between servers (phase 9) | 2, 3, 9 |
| S7 | Token validation on every action, instant revocation | CSRF tokens on every form; LiveView signs its session; but sessions are signed cookies that cannot be revoked before they expire | Server-side session table (token hash, user, created, last seen, IP, user agent); every request and LiveView event checks it; revocation deletes the rows and disconnects live sockets (PubSub); password, 2FA or role changes revoke all of a user's sessions; "sign out everywhere" in the portal | 1b |
| S8 | 15-minute idle timeout | 12 h absolute expiry only | Idle timeout 15 min (configurable lower, not higher) plus 12 h absolute; LiveView pages warn before expiry and redirect to login | 1b |
| S9 | Encryption at rest, external key store | Cloak encrypts TOTP secrets; key in a root-only file on the server | `KeyProvider` behaviour: local file (default) and AWS KMS (the master key stays in KMS; Q-PBX unwraps its data key at start-up); full-disk encryption (LUKS) later, as an option; rotate keys with Cloak's key tags; encrypt carrier passwords and CRM tokens as they arrive; encrypted backups (pgBackRest cipher, restic) | Provider: 1b; backups: 2 |
| S10 | Call recordings encrypted | Recording not built yet | Envelope encryption: a data key per file (AES-256-GCM) wrapped by the master key; voicemail and faxes too; decrypt only while streaming to an authorized user; plaintext never written to persistent disk | 4 |
| S11 | Safe temp location | Every Q-PBX service has `PrivateTmp`; uploads would still use the app's (private) `/tmp` on disk | Uploads and conversions in a per-service tmpfs (`/run/qpbx/tmp`, 0700); FreeSWITCH records into its own tmpfs, then the app encrypts and deletes the plaintext; document converters get a scratch tmpfs per job | 1b (uploads), 4 (media) |
| S12 | systemd and AppArmor, root as little as possible | No Q-PBX service runs as root; ours score 2.2 to 4.2 in `systemd-analyze security`; AppArmor profiles in complain mode; **Debian's Kamailio (9.2) and PostgreSQL (9.6) units are unhardened**; acme.sh runs as root | Hardening drop-ins for Kamailio and PostgreSQL; acme.sh as its own user (reload through a narrow systemd unit); AppArmor in enforce mode (phase 4, as the spec says); a CI check that fails on new root services | 1b (enforce: 4) |

Answered 2026-11-27: 5060 stays open next to TLS 5061 (the default); AWS KMS first; built-in
proof of work as the default challenge; full-disk encryption later.

## Planned features from the phase 1 review

| Feature | Phase | Why there |
| --- | --- | --- |
| Tenant portal page for office IPs (tenant firewall entries; API already exists) | 2 | Phase 2 brings the tenant portal's telephony pages and Kamailio's per-tenant use of these IPs |
| Login rate limits and lockout (S5) | 1b | Security plan |
| Trim FreeSWITCH image dependencies (cairo, X11 came in with the recording codecs' build packages) | 2 | With the FreeSWITCH config work |
| Several addresses per trunk with OPTIONS health checks and failover between them | 2 | Part of trunks (Kamailio dispatcher) |
| Failover between carriers for outbound calls, with caller ID rules per trunk | 2 | Part of outbound routes |
| Backup (alias) numbers for incoming calls, and per-DID guidance on carrier-side forwarding | 2 | Part of DIDs |
| Visual drag-and-drop call-flow editor for IVRs, time conditions and ring groups | 4 (proposed) | Needs those objects; awaiting a decision |

**Spend caps (approved on 2026-11-27; to confirm at phase 2 start whether
that means money-based caps from the start or the recommendation below):** phase 2 uses minute caps per
destination class (local, mobile, international, premium) per hour, day and month, which
need no prices; plus a platform-managed list of high-cost prefixes (satellite, premium-rate,
known fraud ranges) that count as "premium", blocked unless a plan allows them; plus the
velocity alerts. Money-based spend caps need a rate table (cost per minute per prefix); add
it later only if operators ask, and the same table could then feed the usage export.

## Blockers / open questions for phase 1

None. Answers are recorded in `docs/DECISIONS.md` (2026-11-27).

## Open questions for later phases

- **Phase 2, spend caps:** the spec asks for "spend or minute caps per hour, day and month",
  but spend needs per-minute rates and rating is a v1 non-goal. Plans have minute caps per day
  and month only. Where do rates come from, and are hourly caps needed?

## Known bugs

- FreeSWITCH depends on image libraries (cairo, X11) it does not need; harmless, planned to trim.

- The lab LAN has no IPv6, so dual-stack listening (Kamailio, nftables rules) is templated but
  not yet exercised end to end.

- Validation messages built at runtime (for example "unknown feature x") are not translated;
  the fixed ones are.
- Arabic portal texts need review by a native speaker
  (for example "التحويلات الداخلية" for extensions).
- No login rate limit or lockout yet; brute-force alerts are phase 3 (Argon2 slows guessing).
- Per-tenant certificates are issued but Kamailio does not select them by SNI yet (phase 2,
  with its real TLS config); the platform certificate is served for every name meanwhile.
- Tenant office IPs (tenant firewall entries) have an API but no tenant portal page yet;
  platform admins add them today.
- Sessions are signed cookies; they expire but cannot be revoked server-side before expiry.

## Done-when results (phase 1)

Run on 2026-11-27 against the local Debian 12 lab VM (libvirt, bridged to the host LAN), with
packages built from the repo, installed by `ansible/site.yml`, through a real headless Chrome
(`lab/done-when/phase1.mjs`). Certificate from a local Pebble test CA (wildcard mode).
Rerun after the phase 1 review changes (nginx in front, new FreeSWITCH modules): all pass.

| Check | Result |
| --- | --- |
| Platform admin (created with the CLI) sets a password and enrols 2FA in the portal | PASS |
| Platform admin creates a plan, then a tenant with that plan and its first tenant admin | PASS |
| Tenant admin opens the setup link, sets a password, enrols 2FA | PASS |
| Tenant admin logs in with password + TOTP in Arabic (`lang=ar`, `dir=rtl`, Arabic text) | PASS |
| Tenant admin logs in with password + TOTP in English | PASS |
| Allowlist entry added in the portal appears in nftables set `allow_ssh_v4`, applied by `qpbx-fwd` | PASS |
| The firewall form is empty again after the add (browser check) | PASS |
| Removing it in the portal removes it from nftables | PASS |

Also verified in the lab: playbook second run `changed=0`; `/health` `ok` with every component
checked; SIP OPTIONS answered `503` by Kamailio; recovery after reboot; certificates issued in
per_host and wildcard modes and hot-reloaded on renewal; setup emails accepted by an SMTP
server; no AppArmor complaints during the Done-when run.

Not covered by this run: IPv6 (the lab LAN has none), delivery of email to a real mailbox,
Let's Encrypt itself (Pebble stands in), and the spec's full lab hardware (phones, ATA,
carrier), which phase 1 does not need.
