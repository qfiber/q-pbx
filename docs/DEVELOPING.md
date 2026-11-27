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
| `qpbx_edge` | `lib/qpbx/edge/` | `QPBX.Edge` | Kamailio integration: domains, bans, push wake-up, NAT state |
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
(the app's DB user must not be a superuser, or row-level security is bypassed).

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
| `packaging/app/build-in-container.sh` | App and `qpbx-fwd` `.deb` packages into `out/` (Debian 12 image) |
| `packaging/freeswitch/build-in-container.sh` | FreeSWITCH `.deb` into `out/` (Debian 12, about 10 minutes) |
| `lab/create-vm.sh` | Local Debian 12 lab VM (libvirt, bridged to `br0`; `QPBX_LAB_NET=network=default` for NAT) |
| `cd ansible && ansible-playbook site.yml` | Install or update the server in the inventory (lab by default) |
| `lab/acme/pebble.sh <vm-ip>` | Local test ACME server (Pebble) with DNS, to test the certificate modes |
| `cd ansible && ansible-lint` | Lint the playbook and roles |
| `scripts/check_module_docs.sh <base>` | Fails if an area's public API module changed without its `README.md` |
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
`.github/workflows/packages.yml` builds the `.deb` packages as downloadable artifacts.

## Server install (Ansible)

`ansible/site.yml` builds a whole server from the packages in `out/`. Set the inventory
(`ansible/inventories/<env>/`): `qpbx_domain`, `qpbx_management_ips` (must include the machine
running Ansible, or the run stops before touching the firewall), `qpbx_cert_mode`, SMTP
settings, and for `wildcard` mode `qpbx_acme_dns_provider` and `qpbx_acme_dns_env` (keep these in
Ansible Vault). Collections: `ansible-galaxy collection install -r ansible/requirements.yml`.
On the server, `qpbx eval '...'` runs release commands (for example
`QPBX.Release.create_platform_admin("you@example.com", "You")`).
