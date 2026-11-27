# Status

**Current phase:** 1 — Foundation (task breakdown approved 2026-11-27)
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
| P1-01 | Repo and Mix project | `git init`; Phoenix app with LiveView, Ecto/Postgres, Oban; `boundary` configured; area folders `lib/qpbx/{core,events,firewall,notify,web}/` with `QPBX.<Area>` public API modules and a `CLAUDE.md` each; `mix format`, Credo strict, Dialyzer; Commands section of root `CLAUDE.md` filled in | A deliberate cross-boundary call fails `mix compile`; `mix test` green |
| P1-02 | Session hook and doc checks | `.claude/settings.json` Stop hook: blocks finishing when code changed and `docs/STATUS.md` did not; CI script that flags a change to a module's public API module without a change to that module's `CLAUDE.md` | Script tests for both checks (changed / unchanged cases) |
| P1-03 | Core: plans and tenants | `plans` (typed limit columns + JSONB `features`), `tenants` (`sip_domain`, `timezone`, `locale`, `plan_id`, `limit_overrides`); effective-limit resolution (plan + override); unique SIP domain under the platform base domain | Unit tests |
| P1-04 | Core: accounts, roles, audit log | `platform_admins`; `users` (one tenant each) with `user_roles` (tenant admin, tenant user); one-time setup links (minimal SMTP mailer in `QPBX.Notify` plus a CLI command); Postgres RLS safety net on tenant tables (moved here from P1-03: the first tenant-owned table is `users`), Argon2 hashing, session expiry, TOTP 2FA (required for platform admins), `audit_logs` written for every admin change | Unit tests: hashing, TOTP verify/replay, role checks, audit entry per change; RLS test proving a tenant-scoped query cannot see another tenant's rows |
| P1-05 | Portal shell (EN/AR RTL) | LiveView layout with `dir="rtl"` for Arabic, gettext `en` and `ar`, locale switch; login and 2FA pages; platform admin: create plan, create tenant with plan, create tenant admin; tenant admin: landing page and 2FA enrolment | LiveView tests for the full Done-when flow in both locales |
| P1-06 | Health endpoint | `GET /health` (200 `ok` / 503 `degraded`/`down`, no details); `GET /health/details` (token); checker runs every 10 s and caches. Phase 1 checks: PostgreSQL, disk space, Oban backlog, certificate expiry, FreeSWITCH event socket reachable, Kamailio JSON-RPC reachable. Trunk registrations report `not_configured` until phase 2 | Unit tests per check; endpoint tests for each status and for missing/bad token |
| P1-07 | `qpbx-fwd` helper | Separate Go service on a local Unix socket, three commands only (add to set, remove from set, replace set); validates every address and set name against an allowed list; cannot touch rules or chains; writes current nftables state to disk after each change; systemd unit with only `CAP_NET_ADMIN` | Tests for command parsing and validation (rejects bad addresses, unknown sets, extra commands); integration test against real nftables in a Debian 12 VM |
| P1-08 | Firewall module | `firewall_entries` (scope SSH/SIP/HTTPS/all, platform or tenant level, optional expiry, reason, author), audited; allowlist wins over auto-bans; removing the last management IP is refused; applies changes through the helper; PubSub broadcast to all nodes plus 60 s reconcile against the DB; expiry removal | Unit tests for rules; reconcile test with a fake helper; end-to-end test with the real helper |
| P1-09 | Ansible roles and playbook | Roles `kamailio`, `freeswitch`, `qpbx_app`, `postgres`, `storage`, `nftables`, `hardening`, `monitoring`; one `site.yml`; single-host inventory. Phase 1 depth: packages installed, systemd units with the spec's hardening, nftables default deny with named sets, PostgreSQL 16 on localhost, storage folder, unattended upgrades, AppArmor profiles in complain mode, `qpbx-fwd` installed. Kamailio and FreeSWITCH installed and running with minimal config (FreeSWITCH SIP on 127.0.0.1 only); real call config is phase 2 | `ansible-lint`; playbook run twice against a fresh Debian 12 VM with no changes on the second run |
| P1-10 | Certificates | Ansible role `certificates` with acme.sh, two modes: wildcard through DNS-01 (Cloudflare default, any acme.sh DNS provider) or per-hostname through HTTP-01 (portal, SIP name, provisioning, and each tenant domain on tenant create); reload hooks for the web server and Kamailio; expiry feeds the health check | Issuance against a local ACME test server (Pebble) in both modes; renewal hook dry run |
| P1-11 | CI | Format, Credo, Dialyzer, boundary, tests with a Postgres service; doc check from P1-02; build the app as a `mix release` `.deb` on Debian 12; build a FreeSWITCH `.deb` from source (SignalWire token as a CI secret) with only sofia, xml_curl, event_socket, spandsp, conference, callcenter, opus | CI green; both packages install on a fresh Debian 12 VM |
| P1-12 | Lab bring-up and Done-when | Run the playbook on the local Debian 12 VM lab with the CI packages; run the three Done-when checks and record the results here honestly | Done-when results below |

Out of scope for phase 1, on purpose: the modules `telephony`, `edge`, `fax`, `storage`,
`integrations` and `provisioning` are created in the phase that first needs them,
not as empty stubs now. `notify` starts in phase 1 with only the setup-link mailer. Kamailio in-memory sync of firewall lists waits for phase 2, when
Kamailio gets its real config.

## Done

- Project memory files created: `CLAUDE.md`, `docs/STATUS.md`, `docs/DECISIONS.md`, `CHANGELOG.md`.
- P1-01 Repo and Mix project: Phoenix 1.8 app (`QPBX`, binary ids), Oban (queue `notify`),
  areas `core`, `events`, `firewall`, `notify`, `web` with boundaries; public API modules live
  inside their folders (`lib/qpbx/core/core.ex`). `QPBX.Repo` is its own boundary. Credo
  strict and Dialyzer pass. `scripts/check_boundary_enforced.sh` proves a forbidden reference
  fails the build. AGPL-3.0 `LICENSE` added.
- P1-02 Session hook and doc checks: `.claude/settings.json` runs
  `scripts/hooks/session_start.sh` (records the starting commit) and
  `scripts/hooks/require_status_update.sh` (Stop hook; blocks when non-Markdown files outside
  `docs/` changed and `docs/STATUS.md` did not). `scripts/check_module_docs.sh <base>` fails
  when `lib/qpbx/<area>/<area>.ex` changed without `lib/qpbx/<area>/CLAUDE.md`. Tests:
  `scripts/test/doc_checks_test.sh` (8 cases). Hooks need `jq` and `git`.
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

- License: AGPL-3.0 kept, `CLA.md` and `CONTRIBUTING.md`
  added, copyright notice in `README.md`. Code pushed to `github.com/qfiber/q-pbx` (public).

## In progress

- P1-07 `qpbx-fwd` helper (Go).

## Next

- P1-08 Firewall module.

## Blockers / open questions for phase 1

None. Answers are recorded in `docs/DECISIONS.md` (2026-11-27).

## Open questions for later phases

- **Phase 2, spend caps:** the spec asks for "spend or minute caps per hour, day and month",
  but spend needs per-minute rates and rating is a v1 non-goal. Plans have minute caps per day
  and month only. Where do rates come from, and are hourly caps needed?

## Known bugs

- Validation messages built at runtime (for example "unknown feature x") are not translated;
  the fixed ones are.
- Arabic portal texts were written by Claude; a native speaker should review the wording
  (for example "التحويلات الداخلية" for extensions).
- No login rate limit or lockout yet; brute-force alerts are phase 3 (Argon2 slows guessing).
- Sessions are signed cookies; they expire but cannot be revoked server-side before expiry.

## Done-when results (phase 1)

Not run yet.
