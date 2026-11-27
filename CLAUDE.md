# Q-PBX

API-first, multi-tenant cloud PBX with first-class fax. FreeSWITCH (media, fax) and
Kamailio (SIP edge) are driven by an Elixir/Phoenix control plane with PostgreSQL.
Replaces FreePBX for qFiber's Cloud PBX. License: AGPL-3.0. Repo: `qfiber/q-pbx`.

The full product spec is `docs/SPEC.md`. It is the source of truth. If something is unclear,
missing or looks wrong, stop and ask. Do not guess and do not change the architecture.

## Rules (from the spec, "Working with Claude Code: project memory")

- Read `CLAUDE.md`, `docs/STATUS.md` and the touched module's `CLAUDE.md` before starting any task.
- A task is not done until `docs/STATUS.md`, any affected module `CLAUDE.md`, and
  `docs/DECISIONS.md` (if a decision was made) are updated in the same commit as the code.
- Never leave a stale statement: if code contradicts a doc, fix the doc in the same change.
- Work one module at a time through its public API; never reach into another module's internals.
- Every new feature lands with tests and its events documented.

Enforcement: a Claude Code hook at session end blocks finishing if code changed without
`docs/STATUS.md` changing. CI flags a public API change to a module that arrives without a
change to that module's `CLAUDE.md`.

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

Each module folder has its own `CLAUDE.md`: purpose, public API, events emitted and consumed, gotchas.

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
| `mix dialyzer` | Dialyzer (PLT cached in `priv/plts/`) |
| `scripts/check_boundary_enforced.sh` | Proves a cross-boundary reference fails the build |
| `scripts/check_module_docs.sh <base>` | Fails if an area's public API module changed without its `CLAUDE.md` |
| `scripts/test/doc_checks_test.sh` | Tests for the session hook and the module-doc check |

Session hook (`.claude/settings.json`): finishing a session is blocked if code changed and
`docs/STATUS.md` did not. Needs `jq`.

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
