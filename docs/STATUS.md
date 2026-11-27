# Status

**Current phase:** 2 — Core calling and protection (in progress: 2-0 to 2-7 done, next 2-8)
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

- 2-7 Voicemail (done): new `QPBX.Storage` area (per-file AES-256-GCM, data key wrapped by
  the master key, local backend; plain media only in tmpfs `/run/qpbx-media`, shared with
  FreeSWITCH); a mailbox per extension (PIN hashed, email with or without the audio),
  greetings (unavailable, busy, temporary; MP3 or WAV upload), unanswered and busy calls to
  the mailbox (greeting, tone, record, encrypt), `*97` (PIN, counts, play, 7 delete, 9 or #
  keep, 5 repeat), email with the audio (Oban `notify`, the job holds only the file key),
  portal pages for mailbox, greetings and messages (browser playback through an audio
  endpoint for the tenant's admins), voicemail lights with real counts, events
  `VoicemailReceived` and `VoicemailChanged`; English prompts in a new `qpbx-sounds` package.
  Lab: `phase2-voicemail.py` 19/19 with real calls (unanswered call to the mailbox, 5 s message
  stored encrypted and nothing left in tmpfs, email built with the MP3, light on, three wrong
  PINs hung up, right PIN plays and deletes with 7, light off, file gone, a custom greeting
  played from a temporary copy removed after). Found in the lab: deleting an extension left
  its audio files (now deleted first). 229 tests.

- 2-6 Call admission and fraud protection (done): concurrent caps per tenant (total, inbound,
  outbound) and per extension; destination classes per plan (premium, i.e. the high-cost
  prefixes, only when allowed); outbound minute caps per class per hour, day and month, plus
  the total per day and month, with calls cut off when a cap runs out; talk time recorded per
  class and hour; velocity rules (international spike, quiet hours) that alert and block
  international and premium calls, with a platform page to set them and lift blocks;
  emergency calls pass every limit and are logged; refusals audited and announced
  (`LimitReached`, `FraudAlert`). Lab: `phase2-admission.py` 21/21 with real calls (premium
  and barred classes refused, second outbound and inbound call refused, emergency through
  a full cap, a local call cut off after its one minute and the next refused, a spike of 4
  international calls blocking the 4th, local and emergency still working, lifting
  restoring international); `phase2-calls.py` 29/29 and Meow 94/94 still pass. Found in the
  lab: lifting a block let the same spike block again at once (the window is now cleared).
  217 tests.

- 2-5b Echo test, transfers, redirects, SRTP (done; moved into phase 2 by decision, see
  DECISIONS): `*43` echo (loopback service with a tone prompt), blind and attended
  transfers, following a 302; SRTP from phones accepted; a new registration replaces the
  login's older contacts. Meow's live engine test now passes completely (94/94: echo with
  audio, Opus over SRTP on TLS with no loss, DTMF, hold, busy lamps, redirect, blind and
  attended transfer, conference and recording with sound). `phase2-calls.py` 29/29 (adds
  echo and SRTP), and the 2-4, 2-3, 2-2 and phase 1 checks still pass. Found in the lab:
  FreeSWITCH turned every SRTP offer into a call without audio (sofia-sip offer/answer,
  `m=audio 0`); a stale registration of the same login held a busy or redirect for up to
  20 s. Remaining feature codes stay in phase 4.

- 2-0b Busy lamps with Meow (done): Meow's live engine test against the lab (tenant `meow`,
  TLS and UDP lines, optional SRTP): its busy lamp section passes completely (idle, ringing as
  the one called naming 101, on a call, idle), presence (Available) and the voicemail light are
  served, and calls between the two lines pass (answer, busy 486, cancel 487). 60 of 95 checks
  pass; every failure needs the `*43` echo service (feature codes, phase 4): echo, audio levels,
  call statistics, hold, conference, recording, and redirect and transfers aimed at `*43`.
  Found and fixed: FreeSWITCH refused optional SRTP (`a=crypto` on RTP/AVP, 488) until
  `rtp_allow_crypto_in_avp`. Not yet verified: audio itself (no Meow check plays sound without
  `*43`), following a 302, transfers. Grandstream check when a phone is available.

- 2-5 Call control (done): new area `QPBX.Telephony`. FreeSWITCH asks the app for a dialplan
  (`mod_xml_curl`, loopback and a password; nginx refuses `/internal/`) and parks every call;
  one Elixir process per call drives it over the event socket. Routing: extension to
  extension (all devices), forwarding (always, busy, no answer), do not disturb, call waiting,
  follow-me, outbound with the number rule, routes, carrier failover and caller ID per trunk,
  emergency numbers, inbound numbers (any form, backup numbers) to their destination; a
  configuration cache in memory dropped on every change; a static fallback (503) when the app
  does not answer. Lab: `lab/done-when/phase2-calls.py` 20/20 with real calls through Kamailio
  and FreeSWITCH (phones and two simulated carriers); 2-4, 2-3, 2-2 and phase 1 checks still
  pass. Found and fixed in the lab: FreeSWITCH hung up the caller after a failed bridge (no
  failover could follow) until `continue_on_fail`; call waiting marked an extension busy only
  after its call ended; the device login reached carriers as the caller's name. 199 tests.

- Logo added (from the design file, cleaned of editor metadata; renders pixel-identical):
  header of every page, larger on the login page, favicons (SVG and ICO), README (light and
  dark variants). Colour follows the theme, including the system's dark mode.

- 2-4 follow-up (done): protection thresholds moved from Ansible variables to the admin panel
  (Platform > SIP protection), applied by Kamailio within seconds with no restart (flood
  detection now counts per address in 2-second buckets instead of pike, whose threshold is
  fixed at start); every ban (one phone or a whole address) is stored in the database and a
  restarted Kamailio loads it back with its expiry; active bans are listed on the same page
  and can be lifted (Kamailio, database and firewall). Lab: `phase2-protect.py` 31/31 (adds:
  a limit changed live, bans surviving a Kamailio restart, a 60 s ban ending on time after a
  restart, lifting); 2-3, 2-2 and phase 1 checks still pass. 172 tests.

- 2-4 Edge protection (done): in Kamailio, the platform SIP allowlist is never limited;
  scanner user agents and floods (pike) ban the address; REGISTER and INVITE limited per
  address and port (30 a minute by default, 503, a ban at three times); failed logins ban the
  address and port (10 in 15 min) and then the whole address (30); tenant office IPs skip
  flood detection, get three times the per-phone limit and are never banned as a whole (an
  `EdgeAlert` and an audit entry instead). Whole-address bans go to nftables through
  `QPBX.Firewall.ban/4` with a timeout: `qpbx-fwd` now supports element timeouts (block sets
  `flags interval, timeout`), so bans expire in the kernel even while the app is down, and
  survive a helper restart with the time they had left. Kamailio bans of addresses that turn
  out to be allowed are lifted within 5 s. Thresholds are Ansible variables. Lab:
  `lab/done-when/phase2-protect.py` 22/22, and the 2-3, 2-2 and phase 1 checks still pass.
  Found and fixed in the lab: `$shtinc` does not create counters (nothing was counted);
  a ban could hit an office IP added seconds earlier. 166 tests; `qpbx-fwd` unit and
  integration tests cover timeouts.

- 2-3 Kamailio edge (done): phones authenticate REGISTER and INVITE (realm = tenant domain,
  From/To user = authenticated device); carriers recognised by source address (IP trunks, via
  dispatcher) or by the R-URI user Kamailio registered as (registration trunks); every new
  call goes to FreeSWITCH with `X-QPBX-Source`, `X-QPBX-Tenant`, `X-QPBX-Auth-User` or
  `X-QPBX-Trunk`, and outside `X-QPBX-*` headers are removed; calls from FreeSWITCH reach
  registered phones or a trunk (`X-QPBX-Trunk-Edge`) with failover across its addresses and
  OPTIONS pings marking dead ones; registration trunks registered by Kamailio with the
  password pushed over JSON-RPC (in no database view) and reconciled every minute; NAT
  (nathelper, contact aliases, OPTIONS keepalives); in-dialog relaying to outside addresses
  refused; TLS 5061 with one SNI profile per tenant certificate (generated `tls.cfg`, reloaded
  after each certificate change); allow lists (platform SIP allows, tenant office IPs) loaded
  into Kamailio and reloaded on change; all reloads without a Kamailio restart, and a restart
  restores everything. Lab: `lab/done-when/phase2-edge.py` 23/23 (simulated carriers on the
  host). Found and fixed in the lab: Kamailio `$var` turns "no value" into 0 (an unknown
  domain was challenged instead of refused, and in-dialog requests from phones would have been
  refused); a registration trunk sharing a host with an IP trunk made inbound matching
  ambiguous (registration trunks left the dispatcher). Known limits: weight is stored but the
  dispatcher uses priority order only; a trunk host name that does not resolve is skipped until
  the next trunk change; per_host tenant certificates issued before this change do not signal
  their renewals (re-issue them once). 156 tests.

- 2-2 Telephony data and portal pages (done): extensions with call features (DND, call
  waiting, forwarding, follow-me, outside caller ID; plan's `max_extensions` checked under a
  lock); devices, each with its own SIP login `<extension>-<label>` and a password shown once;
  platform and tenant trunks with several addresses, encrypted registration passwords, caller
  ID mode, fax mode and an IP address owned by one IP trunk across tenants; DIDs with backup
  numbers; outbound routes with ordered trunk failover and number rewrite; emergency routes on
  platform trunks; number rules (platform default, tenant override, Israel built in) and
  destination class prefixes (premium = the high-cost list); `QPBX.Core.Numbers` (local
  dialing to E.164, display, class, route selection). Every change announces `ConfigChanged`.
  Tenant admin pages: extensions, devices, numbers, outbound routes, office IPs, number format;
  platform pages: trunks, numbers, numbering. Arabic texts added (to review). Lab:
  `lab/done-when/phase2-config.mjs` 15/15 (a device's one-time password registers; removing
  the device refuses it at once). Found and fixed in the lab: forms kept their old values after
  a save. 153 tests. Not done: a portal page for tenant-owned trunks (Core functions exist);
  country short forms (Israeli 1-800, star numbers) in number rules; DNS SRV for trunk hosts.

- 2-1 Kamailio database view and phone login (done): `sip_credentials` (HA1 only; 24-character
  passwords from the cryptographic generator, shown once; RLS; audited without hashes);
  read-only views `kamailio.credentials` and `kamailio.domains` for the new `qpbx_kamailio`
  role (no other rights); Kamailio loads them into memory (htable) and authenticates
  REGISTER per tenant domain (digest realm = tenant domain; a credential registers only its
  own user); new area `QPBX.Edge` reloads Kamailio's tables over JSON-RPC when Core announces
  `SipCredentialsChanged` or `TenantsChanged` (after commit). Tenant slugs are locked after
  creation. Verified in the lab: two tenants with the same extension 101 register separately;
  wrong password, the other tenant's password, registering another user and an unknown domain
  are refused; a password reset applies at once with no Kamailio restart; second playbook run
  `changed=0`. Fixed on the way: a failed write inside a tenant scope crashed instead of
  returning the error (rollback added). 10 new tests (123).

- 2-0a Busy-lamp trial (done): Kamailio 6.0.8 from the Kamailio project's repository (key
  pinned by checksum, presence, `pua_json` and PostgreSQL modules). On the lab, with a spike
  config (`lab/spike/kamailio-presence.cfg`) and a scripted subscriber
  (`lab/spike/subscribe.py`): JSON updates posted to Kamailio produced correct NOTIFYs for
  busy lamps (early, confirmed, terminated, with the other party's identity), presence (open,
  "On the Phone", on-the-phone activity) and voicemail lights (2 new / 5 saved, then 0 / 7);
  presence ran entirely in memory with no database. Found: a never-used extension came out
  with an empty body (fixed with `force_dummy_dialog`, now a proper idle document), and the
  first voicemail notification is empty until Elixir publishes counts (a design rule now).
  Meow's parser (read in its source) accepts all of these. Design written into the spec
  (Architecture). The lab is back on the production config.

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

- 2-8 CDRs (next).
  (Meow end to end) waits for call control (2-5).

## Next

- Review of phase 1 and answers to the open points in the phase 1 report.
- Phase 1b: security items marked "1b" in the security plan, before phase 2.
- 1b-1 Server-side sessions (done): `user_sessions` (token hash only, RLS), checked on every
  request and LiveView event plus every 30 s; 15 min idle (configurable lower only) and 12 h
  maximum; sweeper every 30 s; revocation on password or 2FA change, from the new account page
  ("Sessions": list, sign out one, sign out everywhere else) and by logout; revoked sessions'
  live pages get a disconnect broadcast; idle warning 2 minutes before the end; secure,
  HTTP-only cookie holding only the token. New CI check: translations complete, no fuzzy
  guesses (it caught a wrong Arabic label). 13 new tests (80 total).
- 1b-2 2FA mandatory for tenant admins (done): they are sent to enrolment at login and cannot
  skip it; tenant users still may. `QPBX.Core.totp_optional?/1`. 2 new tests (82 total).
- 1b-3 Login protection (done): per-IP failure counter in the database (`login_failures`):
  5 failures block 1 h, 5 more 24 h, strikes forgotten after 24 quiet hours; failures are wrong
  passwords or unknown emails, wrong 2FA codes, bad setup links and failed checks; blocked IPs
  get HTTP 429; accounts are never locked (5 failures write an `account.login_failures_alert`
  audit entry); IPs on the platform HTTPS/all allowlist are exempt. Human check on login and
  setup pages (`QPBX.Web.Captcha`): built-in proof of work (default, ALTCHA format, single use,
  5 min), Cloudflare Turnstile, Friendly Captcha v2, Captcha.eu, or none; an outage of an
  outside service lets attempts through (logged), a rejected key does not. Ansible:
  `qpbx_captcha_provider`, `qpbx_captcha_site_key`, `qpbx_captcha_secret`. 18 new tests (100).
- 1b-4 Row-level security in force (done): `QPBX.Core.Scope` (platform or tenant) assigned at
  login for every request and live page; tenant-facing reads (`list_users/1`, `my_tenant/1`,
  `list_my_sessions/1`) run inside the tenant scope on top of their own filters; RLS added on
  `tenants` (own row only). Tests prove an unfiltered query in a tenant scope sees only that
  tenant's users, tenant row and sessions, and cannot write another tenant's rows. 4 new
  tests (104).
- 1b-5 Database roles (done): `qpbx_owner` owns the database and schema and runs migrations
  (`MIGRATION_DATABASE_URL`, start-up step only); the app connects as `qpbx` with data rights
  only; `audit_logs` is insert/select only for the app (migration plus grants that skip it);
  `pg_hba` allows the two roles over TCP on localhost with scram, `postgres` only by local
  peer. Existing installs are converted in place (`REASSIGN OWNED`); new secrets are added to
  `secrets.json` without touching existing ones. Verified in the lab: the app role cannot
  update or delete audit entries, create or drop tables; remote superuser login refused.
- 1b-6 Key provider (done): `QPBX.Core.KeyProvider` gives the vault its master key at start-up:
  `local` (default, from the root-only secrets file) or `aws_kms` (only a KMS-wrapped copy on
  the server, unwrapped with a signed KMS `Decrypt` bound to Q-PBX by an encryption context).
  Ansible switches an existing server without re-encrypting anything (wrap the same key,
  restart, check health, then remove the plain key, only with `qpbx_kms_key_backed_up: true`).
  Tested against `local-kms` (an AWS KMS-compatible server): the same 8 TOTP secrets decrypt
  before, under KMS and after switching back; no plain key left on the server; second run
  `changed=0`. Found and fixed on the way: a rewrite of `secrets.json` left it
  world-readable (0644) for a few minutes in the lab; it is now forced to 0600 every run.
  4 new tests (108).
- 1b-7 Temporary data in memory (done): the app's `TMPDIR` and `PLUG_TMPDIR` are
  `/run/qpbx/tmp` (tmpfs, 0700, app only); nginx buffers request bodies and proxied responses
  in `/run/nginx/{body,proxy}` (tmpfs, 0700, www-data). Verified in the lab: a 3 MB request is
  buffered under `/run/nginx/body`. Fixed on the way: nginx created those folders as `nobody`
  (now named `www-data`), and its file-handle limit was 1024 (now 65536).
- 1b-8 Least privilege (done): hardening drop-ins for Kamailio (no capabilities, read-only
  system, `systemd-analyze security` 9.2 -> 1.9) and PostgreSQL (now starts as `postgres`,
  9.6 -> 1.9); acme.sh runs as `qpbx-acme` (state 0700, webroot readable by nginx, code
  root-owned), and a root-owned path unit (`qpbx-tls.path`) reloads nginx and Kamailio when
  certificate files change. Existing installs are migrated (file ownership, acme.sh's saved
  webroot). Verified in the lab: per_host and wildcard issue and forced renewals as
  `qpbx-acme`, picked up live on 443 and 5061; tenant certificates 0640 for Kamailio; only
  base system daemons run as root (systemd, journald, logind, udevd, sshd, getty,
  unattended-upgrades, qemu guest agent); every Q-PBX-related unit rates "OK". Fixed on the
  way: the nginx switch had left the ACME webroot where nginx could not read it.
- 1b-9 Sobelow in CI (done): `mix sobelow --config` fails CI on any finding. It found a
  missing Content-Security-Policy: added `QPBX.Web.CSP` (scripts only from the site plus the
  configured human-check provider, no inline scripts or eval, no framing, forms to the site
  only); the inline theme script moved to `/theme.js`. Three false positives are skipped with
  their reasons in the code. Browser Done-when checks still pass under the CSP. 3 new tests (111).
- 1b-10 Lab verification (done), `lab/done-when/phase1b.mjs`, browser through an SSH SOCKS
  proxy so the portal sees a non-allowlisted client: see results below. Added on the way: CLI
  `QPBX.Release.revoke_sessions/1`, `qpbx_session_idle_timeout` (lower only), the missing
  Firewall link in the platform menu (an unchecked edit in P1-08 had silently not applied).
  CI had been red since 1b-4 (a formatting slip, then a boundary export): fixed and green.
- Done after the phase 1 review: nginx in front (non-root, real client IP, optional
  ModSecurity), FreeSWITCH modules added (G.729, Opus/MP3 recording, loopback, CDR spool; all
  load in the lab), languages moved to one config list, firewall and plan forms now clear
  after a save (live validation added).

## Phase 2 task breakdown (proposed 2026-11-27)

Answers (2026-11-27): tests use a real Grandstream phone and Meow on the lab
while the server logs are watched; carriers are simulated in the lab (two test carriers
standing in for Partner and Cellcom), and a real carrier is tested later on a public server;
Kamailio 6.0 from the Kamailio project's repository; voicemail encrypted from the start (the
storage layer gets per-file encryption now); backups go to a second local VM, and the timed
restore runs onto a third, fresh VM.

From `docs/SPEC.md` phase 2, plus the phase 2 items in "Planned features" and the security
plan. New areas start here: `QPBX.Telephony` (FreeSWITCH, call control, admission),
`QPBX.Edge` (Kamailio) and `QPBX.Storage` (files).

**Done when (spec):** two tenants with the same extension numbers call internally and
externally with no crossover, changes apply without a reload, a simulated fraud burst is
blocked automatically, busy lamps and voicemail lights work, and the restore succeeds within
a measured time.

| # | Task | Scope |
| --- | --- | --- |
| 2-0 | Busy lamps, presence and voicemail-light spike (2-0a now: Kamailio presence server fed through `pua_json`, checked with scripted subscribers; 2-0b once calls work: Meow's live engine test end to end on the lab) | Kamailio's presence server answers phone subscriptions (Event: dialog, presence and message-summary); Elixir publishes call state and message counts into it. Proven with Meow (desktop, scripted where possible) and a scripted SIP client on the lab; the Grandstream check follows when a phone is available. Design written into the spec before the rest builds on it |
| 2-1 | Kamailio upgrade and database view | Kamailio 6.0 from the project's signed repository; read-only database role with a narrow view (credentials by SIP domain, domains, trunk addresses, bans) |
| 2-2 | Telephony data and portal pages | Extensions (credentials shown once, caller IDs, multiple devices, DND, call waiting, follow-me, forwarding), devices, trunks with several addresses and per-trunk caller ID rules, DIDs with backup numbers, number normalization per tenant (Israeli local formats by default), outbound routes with ordered failover, emergency routes, destination classes and the high-cost prefix list; tenant pages (extensions, devices, office IPs) and platform pages (carriers, trunks, DIDs, prefixes); limits enforced on create |
| 2-3 | Kamailio edge | Tenant from domain or trunk address; digest auth of REGISTER and INVITE; TLS 5061 (default) with per-tenant certificates by SNI and SRTP passed through, UDP/TCP 5060 kept; NAT handling (nathelper, keepalives); registration-based trunks registered by Kamailio; OPTIONS health checks and failover across a trunk's addresses; in-memory caches refreshed on change (no reload); firewall lists and tenant office IPs in Kamailio |
| 2-4 | Edge protection | pike flood detection, per-IP rate limits on REGISTER and INVITE, automatic bans after repeated auth failures shared to nftables with a TTL (`qpbx-fwd` gains element timeouts), scanner user agents blocked, allowlist always wins, a whole office IP never banned without an alert |
| 2-5 | Call control | `mod_xml_curl` handler parks every call; event socket client; one Elixir process per call; ETS configuration cache invalidated on change; static fallback dialplan ("temporarily unavailable" or the DID's carrier failover); routing: extension to extension (all devices), inbound DID, outbound with trunk failover and caller ID rules, emergency routes; extension features (DND, forwarding, follow-me, call waiting) |
| 2-6 | Call admission and fraud protection | Concurrent call caps per extension and tenant (inbound, outbound, total); destination class check; minute caps per class per hour, day and month; high-cost prefixes as premium; velocity rules (international spikes, odd hours) that alert and can block; emergency calls exempt but logged; `limit.reached` event |
| 2-7 | Voicemail | Storage area (local backend, per-file encryption: a data key per file wrapped by the master key); mailboxes with PIN, greetings, recording, voicemail-to-email with audio, web playback; message-waiting lights through the 2-0 mechanism |
| 2-8 | CDRs | One row per call leg from event-socket events, written in batches; import of the FreeSWITCH JSON spool (no CDR lost while the app is down); search and CSV export; daily usage roll-up |
| 2-9 | Automated call tests | SIPp scenarios in CI against real Kamailio and FreeSWITCH (containers in CI only): register, internal call, inbound DID, outbound with limits and failover, voicemail, two tenants with the same extension numbers |
| 2-10 | Backups and restore | pgBackRest (encrypted, point-in-time) and restic (files and the secrets file, separate password) to an off-server target (lab: a second VM), on timers, with backup status in health; a restore playbook; one timed restore onto a fresh VM |
| 2-11 | Leftovers | Trim FreeSWITCH image dependencies; watch tenant certificate renewals; secrets file in the encrypted backup; edit form for plans (today plans can only be created) |
| 2-12 | Done-when verification | Lab and CI: the spec's checks, measured restore time |

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
| S10 | Call recordings encrypted | Recording not built yet | Envelope encryption: a data key per file (AES-256-GCM) wrapped by the master key; voicemail and faxes too; decrypt only while streaming to an authorized user; plaintext never written to persistent disk | 2 (storage layer and voicemail), 4 (recordings, faxes) |
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
| Visual drag-and-drop call-flow editor for IVRs, time conditions and ring groups | 4 | Approved for 1.0; needs those objects |

**Spend caps (approved 2026-11-27):** phase 2 uses minute caps per destination
class (local, mobile, international, premium) per hour, day and month, which need no prices;
plus a platform-managed list of high-cost prefixes (satellite, premium-rate, known fraud
ranges) that count as "premium", blocked unless a plan allows them; plus the velocity alerts.
Money-based caps (with a rate table per prefix) only later, if operators ask.

## Blockers / open questions for phase 1

None. Answers are recorded in `docs/DECISIONS.md` (2026-11-27).

## Open questions for later phases

- Voicemail for tenant users: users are not linked to an extension yet, so only tenant admins
  see and play messages in the portal (phones use `*97`). The spec gives tenant users their
  own extension's voicemail: needs a user-extension link (proposed for 2-11 or phase 3).
- Voice prompts: FreeSWITCH's "Callie" English set; packagers (including FreeSWITCH's own
  spec file) list it as MPL. To confirm before the first public release.

- ~~Phase 2, spend caps~~ Answered: minute caps per destination class plus a high-cost
  prefix list (see "Planned features").

## Known bugs

- Kamailio logged one parse error on Meow's TLS connection (`bad header field [INVITE ...`)
  during the first Meow run, alongside FreeSWITCH's 488 refusals; not seen again after the
  SRTP fix. Watch for it.

- The login page's "Log in" button renders as plain text, not a filled button (seen on
  2026-11-27; predates the logo). To check with the next portal work.

- One unexplained test failure in a full `mix test` run on 2026-11-27 (2-4 follow-up); it did
  not come back in 13 further runs and its name was not captured. Watch CI for a repeat.

- FreeSWITCH depends on image libraries (cairo, X11) it does not need; harmless, planned to trim.

- Deleting a tenant (no portal action yet; only by hand) leaves its encrypted media files on
  disk: the database cascade removes the rows only.

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

## Lab results (phase 1b)

Run on 2026-11-27 on the lab VM (`lab/done-when/phase1b.mjs`, idle timeout set to 60 s for
the run, then back to 15 minutes; phase 1 checks rerun afterwards: 8/8 pass).

| Check | Result |
| --- | --- |
| Setup page carries a proof-of-work challenge for a non-allowlisted client | PASS |
| The real browser solves it; account set up with 2FA | PASS |
| Second login with proof of work and 2FA | PASS |
| "Sign out everywhere else" sends the other browser's open page to login at once | PASS |
| CLI revocation ends an open page within 40 s | PASS |
| Idle warning shown; the idle session ends and its page goes to login | PASS |
| No Content-Security-Policy violations in the browser | PASS |
| 5 failed logins from one IP block it (HTTP 429); a missing proof of work counts as a failure | PASS |
| App database role cannot update or delete audit entries or change the schema | PASS |
| Only base system daemons run as root | PASS |
| No AppArmor complaints during the run | PASS |
| Every Q-PBX-related unit rates "OK" in `systemd-analyze security` | PASS |
| Secrets file is root-only (600) | PASS |

Not covered: real AWS KMS (tested against `local-kms`), the three outside CAPTCHA services
(tested against stubbed APIs; they need accounts), and IPv6.

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
