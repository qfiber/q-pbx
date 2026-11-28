# Developing Q-PBX

API-first, multi-tenant cloud PBX with first-class fax. FreeSWITCH (media, fax) and
Kamailio (SIP edge) are driven by an Elixir/Phoenix control plane with PostgreSQL.
Replaces FreePBX for qFiber's Cloud PBX. License: AGPL-3.0. Repo: `qfiber/q-pbx`.

The full product spec is `docs/SPEC.md`. It is the source of truth. If something is unclear,
missing or looks wrong, stop and ask. Do not guess and do not change the architecture.

## Rules

- Before starting a task, read this file, `docs/STATUS.md` and the `README.md` of the module
  you will touch.
- A task is done when `docs/STATUS.md`, any affected module `README.md`, and
  `docs/DECISIONS.md` (if a decision was made) are updated in the same commit as the code.
- Never leave a stale statement: if code contradicts a doc, fix the doc in the same change.
- Work one module at a time through its public API; never reach into another module's internals.
- Every new feature lands with tests and its events documented.
- Tenant-facing code passes the request's `QPBX.Core.Scope` to Core; Core runs tenant scopes
  under row-level security (`Scope.run/2`) and still filters by tenant explicitly.

CI flags a public API change to a module that arrives without a change to that module's
`README.md`.

## Architecture summary

- All SIP enters through Kamailio (service IP, 5060 UDP/TCP, 5061 TLS). Kamailio finds the
  tenant (domain or trunk IP), checks bans and rate limits, authenticates phones against
  credential hashes in Postgres (read-only view), and forwards to the active FreeSWITCH.
- FreeSWITCH listens for SIP on 127.0.0.1 only, keeps no tenant config, and asks Elixir via
  `mod_xml_curl` for dialplan and configuration. Elixir answers from an ETS cache.
- Every call is parked and driven by an Elixir call process over the event socket. Features
  are written once, in Elixir. The only XML dialplan is the static fallback for when Elixir is down.
- Elixir stores state in Postgres and files through the `Storage` behaviour (local disk in v1, S3 later).
- Events go on one internal bus (Phoenix.PubSub) and feed webhooks, notifications, flows and the portal.
- Fault isolation: separate systemd services; one supervisor per module; one process per
  call/flow run/fax job; Oban queues per module (`calls`, `fax`, `webhooks`, `notify`, `crm`,
  `provisioning`); timeouts and circuit breakers on every outside call; document converters
  run as separate OS processes with limits.
- Multi-tenancy: every non-platform row has `tenant_id`; UUID primary keys; isolation at
  Kamailio, FreeSWITCH contexts and Postgres (tenant-scoped queries plus RLS as safety net).
- Deployment: Debian 12, native install with Ansible and systemd. No Docker in production
  (Docker only in CI and a later demo). Single server first, active/standby later with no
  phone, trunk or customer config changes.

## Module map

One Mix project. One top-level area per folder under `lib/qpbx/`, public API module
`QPBX.<Area>`, boundaries enforced by the `boundary` library. A module is used only through
its public API module or its events. No module touches another module's tables or internals.

| Spec label | Folder | Public API | Owns |
| --- | --- | --- | --- |
| `qpbx_core` | `lib/qpbx/core/` | `QPBX.Core` | Tenants, users, plans, limits, extensions, routing objects, Ecto schemas |
| `qpbx_events` | `lib/qpbx/events/` | `QPBX.Events` | Event bus: typed, versioned event structs on Phoenix.PubSub |
| `qpbx_telephony` | `lib/qpbx/telephony/` | `QPBX.Telephony` | `mod_xml_curl` handler, event socket, call processes, call admission |
| `qpbx_edge` | `lib/qpbx/edge/` | `QPBX.Edge` | Kamailio integration: domains, credentials, bans, push wake-up, NAT state (started in phase 2) |
| `qpbx_fax` | `lib/qpbx/fax/` | `QPBX.Fax` | Fax boxes, send/receive jobs, document conversion |
| `qpbx_storage` | `lib/qpbx/storage/` | `QPBX.Storage` | `Storage` behaviour, local and S3 backends |
| `qpbx_notify` | `lib/qpbx/notify/` | `QPBX.Notify` | Alerts, notifications, preferences, email, push |
| `qpbx_integrations` | `lib/qpbx/integrations/` | `QPBX.Integrations` | Webhooks, flows, CRM adapters |
| `qpbx_provisioning` | `lib/qpbx/provisioning/` | `QPBX.Provisioning` | Device templates, HTTPS provisioning |
| `qpbx_firewall` | `lib/qpbx/firewall/` | `QPBX.Firewall` | Allow/block lists, nftables and Kamailio sync |
| `qpbx_web` | `lib/qpbx/web/` | `QPBX.Web` | Phoenix: LiveView portal, REST API, health endpoint |

The firewall helper `qpbx-fwd` is a separate Go program in `fwd/` (see `fwd/README.md`).

Each module folder has its own `README.md`: purpose, public API, events emitted and consumed, gotchas.

## Commands

Toolchain: see `.tool-versions` (Elixir 1.18.4 / OTP 28). Dev Postgres 16:
`podman run -d --name qpbx-pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 docker.io/library/postgres:16`,
then `podman exec qpbx-pg psql -U postgres -c "create role qpbx login password 'qpbx' createdb"`
(the app's DB user must not be a superuser, or row-level security is bypassed). Production
uses two roles (`qpbx_owner` for migrations, `qpbx` for the app); development uses one.

| Command | Does |
| --- | --- |
| `mix setup` | Deps, database, assets |
| `mix phx.server` | Run the app on localhost:4000 |
| `mix test` | Test suite |
| `mix precommit` | Compile with warnings as errors, format, Credo strict, tests |
| `mix run -e 'QPBX.Release.create_platform_admin("you@example.com", "You")'` | Dev: first platform admin; prints its setup link (prod: `bin/qpbx eval '...'`) |
| `mix dialyzer` | Dialyzer (PLT cached in `priv/plts/`) |
| `scripts/check_boundary_enforced.sh` | Proves a cross-boundary reference fails the build |
| `cd fwd && go test ./...` | `qpbx-fwd` unit tests |
| `fwd/integration_test.sh` | `qpbx-fwd` against real nftables in a Debian 12 container |
| `packaging/app/build-in-container.sh` | App, `qpbx-fwd` and `qpbx-sounds` (English voice prompts) `.deb` packages into `out/` (Debian 12 image) |
| `packaging/freeswitch/build-in-container.sh` | FreeSWITCH `.deb` into `out/` (Debian 12, about 10 minutes) |
| `lab/create-vm.sh` | Local Debian 12 lab VM (libvirt, bridged to `br0`; `QPBX_LAB_NET=network=default` for NAT) |
| `cd ansible && ansible-playbook site.yml` | Install or update the server in the inventory (lab by default) |
| `lab/acme/pebble.sh <vm-ip>` | Local test ACME server (Pebble) with DNS, to test the certificate modes |
| `node lab/done-when/phase1b.mjs <vm-ip>` | Phase 1b security checks in the lab (needs `qpbx_session_idle_timeout=60`) |
| `node lab/done-when/phase2-config.mjs <vm-ip>` | 2-2 lab check: telephony pages end to end, device registration |
| `lab/done-when/phase2-admission.py <vm-ip>` | 2-6 lab check: call admission and fraud protection with real calls |
| `ci/calls/test.sh` | Call tests: a fresh Debian 12 systemd container (podman), the playbook into it (`ansible/inventories/ci`), then the SIPp suite (calls, the API, signed webhooks, a usage alert); needs the packages in `out/` (about 5 minutes) |
| `ci/calls/run.py debian@<vm-ip> -i <key>` | The SIPp suite alone against any installed server (needs `sip-tester` there) |
| `QPBX_LAB_NAME=qpbx-backup lab/create-vm.sh` | The lab's backup target (a second VM; group `qpbx_backup` in the lab inventory) |
| `cd ansible && ansible-playbook restore.yml -e qpbx_restore_confirm=yes` | Rebuild the inventory's server from its backups (a fresh machine; `-e qpbx_restore_target_time=...` for a point in time) |
| `lab/done-when/phase2.py <vm-ip> <host-ip>` | Phase 2 done-when: every phase 2 lab check, then the spec's five conditions (add `MEOW_TEST=… MEOW_HOME=…` for the Meow client) |
| `lab/done-when/phase3-api.py <vm-ip>` | 3-1 and 3-2 lab check: the `/v1` API through nginx (keys, scopes, isolation, idempotency, pages, rate limit, OpenAPI, explorer; every resource kind, a device added through the API registering over SIP) |
| `lab/done-when/phase3-events.py <vm-ip>` | 3-3 lab check: call and registration events for real SIP traffic (`--skip-expiry` saves the two-minute wait) |
| `lab/done-when/phase3-outbound.py <vm-ip> <receiver-ip>` | 3-4 lab check: the outbound client from the server (real DNS and certificates; inside names, addresses and redirects refused); the HTTPS receiver (`lab/tools/http_receiver.py`, certificate from `lab/tools/lab-ca.sh`) runs on the backup VM |
| `lab/done-when/phase3-webhooks.py <vm-ip> <receiver-ip>` | 3-5 lab check: webhooks for real calls and registrations to the HTTPS receiver on the backup VM (signatures, order, delivery time, retries) |
| `node lab/done-when/phase3-stream.mjs <vm-ip>` | 3-6 lab check: the live event stream through nginx (two tenants, a real call, a type filter, revocation) |
| `lab/done-when/phase3-click.py <vm-ip>` | 3-7 lab check: click-to-call, transfer and hang up through the API with real phones; an outside number; admission refusing a forbidden class |
| `lab/done-when/phase3-alerts.py <vm-ip> <receiver-ip>` | 3-8 lab check: alerts end to end (real email to the catcher `lab/tools/smtp_sink.py` and a bounce, signed alert webhooks generic and Alertmanager, acknowledge from the email link, resolved) |
| `lab/done-when/phase3-sources.py <vm-ip>` | 3-9 lab check: alert sources with real failures (a trunk's carrier stops answering, FreeSWITCH stopped, a usage threshold crossed by real calls, a phone banned for wrong passwords), each raised and resolved |
| `node lab/done-when/phase3-explorer.mjs <vm-ip>` | 3-1 lab check: the API explorer in Chrome (sends requests with a typed key, uploads a greeting from a file, no CSP violations) |
| `lab/done-when/phase2-tenants.py <vm-ip>` | Two tenants with the same numbers, no crossover in or out; changes apply without restarting Kamailio or FreeSWITCH |
| `lab/done-when/phase2-restore.py <vm-ip>` | 2-10 lab check: timed restore of the lab server onto a fresh VM |
| `sudo qpbx-backup db\|files` (on a server) | One backup now (the timers run them nightly) |
| `lab/done-when/phase2-cdrs.py <vm-ip>` | 2-8 lab check: call records of real calls, including one made while the app is stopped |
| `lab/done-when/phase2-voicemail.py <vm-ip>` | 2-7 lab check: voicemail with real calls (message, encryption, email, lights, *97) |
| `lab/done-when/phase2-calls.py <vm-ip>` | 2-5 lab check: real calls (extensions, features, outbound, failover, inbound, fallback) |
| `lab/done-when/phase2-protect.py <vm-ip>` | 2-4 lab check: floods, scanners, failed logins, rate limits, office IPs |
| `lab/done-when/phase2-edge.py <vm-ip> <host-ip>` | 2-3 lab check: Kamailio edge with simulated carriers on this host |
| `lab/tools/sip_register.py <ip> <user> <domain> <password>` | Test a SIP registration against the lab |
| `cd ansible && ansible-lint` | Lint the playbook and roles |
| `scripts/check_module_docs.sh <base>` | Fails if an area's public API module changed without its `README.md` |
| `mix sobelow --config` | Security scan (CI fails on any finding) |
| `scripts/check_translations.sh` | Fails on fuzzy or missing translations |
| `scripts/test/module_docs_test.sh` | Tests for the module-doc check |


Each area's public API module lives inside its folder (`lib/qpbx/core/core.ex` defines
`QPBX.Core`) and declares its boundary with `use Boundary, deps: [...], exports: [...]`.
`QPBX.Repo` is its own boundary; each area queries only its own tables through it.

## Coding rules

- `mix format`, Credo (strict) and Dialyzer run in CI; boundary violations fail the build.
- External systems sit behind behaviours (storage, CRM, push, email) so adapters can be swapped and tested alone.
- Every module has its own tests and telemetry events.
- Small files and functions: a module file past roughly 400 lines is a signal to split it.
- Numbers stored in E.164. Secrets encrypted with Cloak, key outside the database.
- Outbound requests to tenant-chosen addresses: HTTPS only by default, no private, loopback or
  link-local targets (checked after DNS resolution and on every redirect), size and time limits.
- Target Debian 12. No Docker in production.

## CI

GitHub Actions: `.github/workflows/ci.yml` runs every check above on pushes and pull requests;
`.github/workflows/packages.yml` builds the `.deb` packages as downloadable artifacts;
`.github/workflows/calls.yml` runs the call tests (`ci/calls/test.sh`) with the packages built
from the commit (FreeSWITCH from a cache keyed on `packaging/freeswitch/`).

## Server install (Ansible)

`ansible/site.yml` builds a whole server from the packages in `out/`. Set the inventory
(`ansible/inventories/<env>/`): `qpbx_domain`, `qpbx_management_ips` (must include the machine
running Ansible, or the run stops before touching the firewall), `qpbx_cert_mode`, SMTP
settings, the human check (`qpbx_captcha_provider`: `pow`, `turnstile`, `friendly_captcha`,
`captcha_eu` or `none`, with site key and secret for the outside services), and for `wildcard` mode `qpbx_acme_dns_provider` and `qpbx_acme_dns_env` (keep these in
Ansible Vault). Requests to tenant-chosen addresses (webhooks) are HTTPS only:
`qpbx_outbound_allow_cidrs` (inside networks you trust; default none) and
`qpbx_outbound_ca_pem` (extra certificate authorities, PEM; default none). Collections: `ansible-galaxy collection install -r ansible/requirements.yml`.
On the server, `qpbx eval '...'` runs release commands (for example
`QPBX.Release.create_platform_admin("you@example.com", "You")`).

## Languages

The portal and emails use Gettext. Each language has its own files:
`priv/gettext/<code>/LC_MESSAGES/*.po` (portal) and `priv/gettext_notify/<code>/LC_MESSAGES/*.po`
(emails). To add one: `mix gettext.merge priv/gettext --locale <code>` and the same for
`priv/gettext_notify`, translate, then add `%{code: ..., name: ..., dir: "ltr" | "rtl"}` to
`config :qpbx, :locales` in `config/config.exs`. After changing texts in code, run
`mix gettext.extract --merge` and fill in every language's new entries.

## Backups

Set in the inventory: `qpbx_backup_enabled: true`, `qpbx_backup_host` (an SFTP server; when it
is in group `qpbx_backup`, the `backup_target` role sets up a chrooted SFTP-only account and
authorizes the server's key, otherwise authorize `/etc/qpbx-backup/id_ed25519.pub` there by
hand) and `qpbx_backup_password` (restic; in Ansible Vault). Keep that password somewhere off
the server as well: a restore needs it to get the secrets file back, and the database backups'
cipher is in that file. Every night pgBackRest backs up the database (WAL is archived all the
time, so a restore reaches the latest state or any point in between) and restic backs up
`/etc/qpbx` and the data folder; `/health/details` shows how old the last backups are. To
rebuild a server: point the inventory at a fresh Debian 12 machine and run `restore.yml` (see
Commands). The lab keeps its backup password in `~/.local/share/qpbx-lab/backup-password`
(create it with a random value before the first run).

## nginx

nginx (`ansible/roles/nginx`) terminates TLS and proxies to the app on 127.0.0.1:4000. Behind a
CDN set `qpbx_cdn` (`cloudflare`, `imperva` with `qpbx_cdn_ranges`, or `custom` with
`qpbx_cdn_ip_header` and `qpbx_cdn_ranges`). `qpbx_nginx_modsecurity: true` loads ModSecurity
in detection-only mode; put rules in `/etc/nginx/qpbx-modsecurity.d/*.conf` and other nginx
additions in `/etc/nginx/qpbx.d/*.conf`.

## Master key in AWS KMS

1. Back up the `cloak_key` value from `/etc/qpbx/secrets.json` somewhere safe off the server.
2. Create a KMS key (symmetric) and an IAM user allowed `kms:Encrypt` and `kms:Decrypt` on it.
3. Set in the inventory (credentials in Ansible Vault): `qpbx_key_provider: aws_kms`,
   `qpbx_kms_region`, `qpbx_kms_key_id`, `qpbx_aws_access_key_id`,
   `qpbx_aws_secret_access_key`, `qpbx_kms_key_backed_up: true`, then run the playbook.

Going back to a local key: put the backed-up value back as `cloak_key` in
`/etc/qpbx/secrets.json` (mode 0600), delete `/etc/qpbx/master-key.kms`, set
`qpbx_key_provider: local` and run the playbook.
