# Q-PBX Product Spec

Nov 26, 2026

## Overview

Q-PBX is a new, API-first, multi-tenant cloud PBX with full fax support, built on FreeSWITCH with an Elixir/Phoenix control plane. It replaces FreePBX for qFiber's Cloud PBX service and ships as open source under the AGPL.

**Goals**

- Config changes take effect instantly: no generated config files, no manual reloads.
- Every feature is reachable through a public REST API and emits webhook events.
- One platform serves many tenants with hard isolation and per-tenant limits.
- Fax is a first-class feature, not an add-on.
- Starts on one server with tested backups, and grows to active/standby failover without any client changes.

**Non-goals for version 1**

- Built-in billing, rating or invoicing (plans and limits only; scheduled as phase 11, after 1.0).
- Reseller hierarchy (scheduled as phase 10, after 1.0).
- WebRTC browser softphone.
- A separate Q-PBX mobile app. Meow, qFiber's existing softphone, is the desktop and mobile app.
- Country-specific regulatory logic. Each operator configures emergency routes, caller ID rules and compliance for their own country; Q-PBX only provides the generic tools to do it.
- Arabic voice prompts (deferred; English prompts first).

**Version 1.0 scope**

Version 1.0 is deliberately small, and it goes live with one real tenant before anything else is built.

- **In 1.0:** tenants and plans, core calling, voicemail, CDRs, busy lamps and voicemail indicators, IVR, time conditions, ring groups, recording, the API and webhooks, notifications (email, generic webhook, in-portal, push), usage alerts, fraud limits, basic fax (fax-to-email, sending from the portal and API), Meow integration, and a FreePBX importer.
- **After 1.0, in this order:** Grandstream provisioning, queues, conferencing and paging, email-to-fax, the flow builder, the first CRM adapter, extra alert channels and escalation, high availability.

**Decisions locked in**

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

## Architecture

Elixir owns every decision. Kamailio and FreeSWITCH keep no tenant config of their own and ask Elixir whenever they need it, so there are no config files to regenerate and any node can be replaced.

&#91;embedded content: Q-PBX architecture · edge, media, control plane, data\]

All SIP traffic enters through Kamailio. Media and fax run on FreeSWITCH, which asks Elixir for every route. Elixir stores state in Postgres and files on local storage, and pushes events out to email, webhooks and CRMs. Phones fetch their provisioning over HTTPS directly from Elixir, and the Meow apps use the REST API for everything except calls.

**A call, step by step**

1. A phone or carrier sends an INVITE to Kamailio's service IP.
2. Kamailio finds the tenant from the domain or the trunk IP, checks bans and rate limits, authenticates phones, and forwards to the active FreeSWITCH node.
3. FreeSWITCH asks Elixir for the dialplan through `mod_xml_curl`. Elixir runs call admission (limits, destination class, spend) and returns one short dialplan that parks the call under Elixir's control.
4. An Elixir call process then controls the call over the event socket (IVR, queue, transfer, recording) and publishes every event to the bus, which feeds webhooks, flows and the live portal.
5. On hangup the CDR goes to Postgres and the recording to file storage.

**Who does what in SIP**

- **Authentication:** Kamailio authenticates every REGISTER and INVITE from phones against credential hashes in Postgres, through a read-only view. FreeSWITCH accepts SIP only from Kamailio and trusts it. `mod_xml_curl` serves dialplan and configuration, not a user directory.
- **One routing path:** every call is parked and driven by an Elixir call process over the event socket. Features are written once, in Elixir, never also as XML dialplan. The only XML is the static fallback used when Elixir is down.
- **Carrier trunks:** IP-authenticated trunks are admitted by Kamailio by source address. Registration-based trunks are registered by Kamailio too, so FreeSWITCH nodes hold no carrier state and stay interchangeable.
- **Busy lamps, presence and voicemail indicators:** Kamailio answers the phones' subscriptions, and Elixir publishes call state, parking slots and message-waiting counts from call events. FreeSWITCH cannot do this natively here because it does not hold the registrations. Design, confirmed by the phase 2 spike (2-0a, `lab/spike/`):
  - Kamailio runs its presence server (`presence`, `presence_xml`, `presence_dialoginfo`, `presence_mwi`) entirely in memory: lamp states are runtime state, not configuration.
  - Elixir publishes each change as JSON to a localhost-only HTTP endpoint on Kamailio, which passes it to `pua_json`; Q-PBX needs no SIP stack of its own. Packages: `dialog` (busy lamps: early = ringing, confirmed = on a call, terminated = idle, with the other party's identity and the call direction), `presence` (open or closed, a note such as "On the Phone", an RPID busy activity for do-not-disturb) and `message-summary` (new and saved messages).
  - A watched extension with no state yet is sent as idle (`force_dummy_dialog`), never as unknown. Elixir publishes every mailbox's counts at start-up and when a mailbox is created, and republishes every live state when it or Kamailio restarts (Kamailio's memory is then empty).
  - Presentities are keyed by the tenant's SIP domain; Kamailio accepts a SUBSCRIBE only for the subscriber's own domain, so one tenant never sees another's lamps. Park slots are presentities like extensions.
  - Still to prove: the same lamps on a Grandstream phone (when one is available) and in Meow through a real call (2-0b, once call control exists). With two Kamailio nodes (HA) the presence state is shared over DMQ.

**High availability (after the single-server phase)**

- **Kamailio:** two nodes sharing a floating IP via keepalived, with registrations replicated over DMQ so the standby already knows every phone.
- **FreeSWITCH:** an active and a standby node. On failover, calls in progress drop and new calls work on the standby within 30 seconds. The nodes are interchangeable because their config comes from Elixir.
- **Elixir:** two clustered BEAM nodes (libcluster). Oban jobs live in Postgres, so a webhook or fax job is never lost.
- **PostgreSQL:** Patroni with etcd and a synchronous replica.
- **File storage:** the S3 backend, or the local folder replicated to the second server.

**Why it is fast**

- Config lookups come from an in-memory ETS cache, not from disk or SQL.
- Extensions, routes, IVRs and time conditions apply on the next call with no reload. Queues, conference profiles and trunk registrations need one targeted command, which Elixir sends automatically on change.
- Kamailio keeps routing data in shared memory and handles registrations without touching FreeSWITCH.
- On the BEAM, each call and each flow run is a lightweight process, so one slow integration never blocks a call.

## Modular design and fault isolation

Q-PBX is built as separate modules with clear boundaries that talk through defined APIs and events, so one part crashing never takes down the rest. A fax converter crash, a slow CRM or a webhook backlog must never stop a phone call.

**Isolation at the server level**

- Kamailio, FreeSWITCH, the Elixir app, PostgreSQL and the firewall helper are separate systemd services with `Restart=on-failure` and restart limits.
- **If the Elixir app is down:** calls in progress continue, because media lives in FreeSWITCH. Kamailio keeps registrations in its own memory. New calls use a minimal static fallback dialplan in FreeSWITCH (`mod_xml_curl` falls back to it when Elixir does not answer) that plays a "temporarily unavailable" message or sends DIDs to the carrier's failover number.
- **If FreeSWITCH is down:** the portal, API, fax inbox, notifications and provisioning keep working, and a critical alert goes out.
- **If PostgreSQL is down:** Elixir serves routing from its ETS cache for existing config, queues writes such as CDRs, and alerts.
- Document converters run as separate OS processes with CPU time and memory limits, never inside the Elixir VM.

**Isolation inside Elixir**

- Each module runs under its own supervisor. A crash restarts only that module's processes.
- Every call, flow run and fax job is its own process, so a bug in one affects only that one.
- Oban queues per module (`calls`, `fax`, `webhooks`, `notify`, `crm`, `provisioning`), each with its own concurrency limit, so a webhook backlog cannot starve fax or alerts.
- Every outside call (CRM, webhook targets, SMTP, push services) has a timeout and a circuit breaker; a failing endpoint is paused and alerted, not retried forever.

**Code structure**

One Mix project in `qfiber/q-pbx`, with one top-level module per area under `lib/qpbx/` and the boundaries between them enforced by the `boundary` library. This gives the isolation of an umbrella without eleven separate apps to maintain:

| Module | Owns |
| --- | --- |
| `qpbx_core` | Tenants, users, plans, limits, extensions, routing objects, Ecto schemas |
| `qpbx_events` | The event bus: typed, versioned event structs on Phoenix.PubSub |
| `qpbx_telephony` | FreeSWITCH: `mod_xml_curl` handler, event socket, call processes, call admission |
| `qpbx_edge` | Kamailio integration: domains, bans, push wake-up through the configured push provider, NAT state |
| `qpbx_fax` | Fax boxes, send and receive jobs, document conversion |
| `qpbx_storage` | The `Storage` behaviour with local and S3 backends |
| `qpbx_notify` | Alerts, notifications, preferences, email, push |
| `qpbx_integrations` | Webhooks, flows, CRM adapters |
| `qpbx_provisioning` | Device templates and HTTPS provisioning |
| `qpbx_firewall` | Allow and block lists, nftables and Kamailio sync |
| `qpbx_web` | Phoenix: LiveView portal, REST API, health endpoint |

The names in the table are labels. For example, `qpbx_fax` lives in `lib/qpbx/fax/` and its public API module is `QPBX.Fax`.

**Rules that keep it readable**

- A module is used only through its public API module (for example `QPBX.Fax.send/2`) or by listening to its events. No module touches another module's tables or internals.
- Boundaries are enforced in CI with the `boundary` library, so a forbidden call fails the build.
- External systems sit behind behaviours (storage, CRM, push, email), so each adapter can be swapped and tested alone.
- `mix format`, Credo (strict) and Dialyzer run in CI; every module has its own tests and telemetry events.
- Small files and functions: a module file past roughly 400 lines is a signal to split it.

## Deployment

Version 1 runs on a single Debian 12 server, installed natively with Ansible and systemd, no Docker. It is laid out so a second server and a witness can be added later without changing any phone, trunk or customer setting.

**Install method**

- **OS:** Debian 12, the best-supported platform for FreeSWITCH.
- **Ansible roles:** `kamailio`, `freeswitch`, `qpbx_app`, `nginx`, `certificates`, `postgres`, `storage`, `nftables`, `hardening`, `monitoring`. One playbook builds a full server; the inventory lists one host in every group.
- **Packages built in CI:** a FreeSWITCH package with only the modules Q-PBX uses (sofia, xml\_curl, event\_socket, spandsp, conference, callcenter, opus), and the Elixir app as a `mix release` package. Built once, installed the same everywhere.
- **systemd units** for every service, logs in journald.
- **Docker:** not used in production. Used in CI for integration tests, and later for a one-command demo with the open source release.

**Certificates**

- Two certificate modes, chosen per installation:
  - **Wildcard (default):** one Let's Encrypt certificate for `*.pbx.qfiber.co.il`, issued through DNS validation and renewed automatically, covering every tenant SIP domain, the portal and provisioning. Cloudflare is the default DNS provider; any DNS provider that acme.sh supports can be configured.
  - **Per hostname:** for operators without a DNS API, one Let's Encrypt certificate per name (portal, SIP service name, provisioning, and each tenant SIP domain, issued when the tenant is created) through HTTP-01 on port 80. Kamailio and the web server pick the certificate by SNI.
- Kamailio and the web server reload it on renewal, and the health checks watch its expiry.

**Single-server layout**

| Component | Listens on | Notes |
| --- | --- | --- |
| Kamailio | Service IP: UDP/TCP 5060, TLS 5061 | The only SIP entry point; NAT handling, push, bans |
| FreeSWITCH | SIP on 127.0.0.1 only; RTP on the service IP | Never reachable by SIP from outside |
| nginx | 80 and 443 | TLS for the portal, API and provisioning, ACME challenges, real client IP from a trusted CDN header, optional ModSecurity; runs without root |
| Elixir app | 127.0.0.1:4000 behind nginx | Portal, API, provisioning, health endpoint, `mod_xml_curl` on localhost |
| PostgreSQL 16 | localhost | Plain install, no Patroni yet |
| File storage | Local NVMe folder | Recordings, voicemail, faxes, prompts |

- **Service IP and DNS:** a dedicated second IP on the server and a name such as `sip.pbx.qfiber.co.il`. Phones, carriers and provisioning all use it; it becomes the floating IP when HA is added.
- **Dual-stack IPv4 and IPv6** everywhere a client connects: the service IP has an IPv4 and an IPv6 address (with A and AAAA records), and Kamailio, RTP, the portal, the API, provisioning and the firewall all handle both. FreeSWITCH bridges between the families, so a phone on IPv6 can call a carrier that is IPv4-only. Each trunk uses the address family its carrier supports.
- **Public IP directly on the server,** no NAT in front.
- **Rough sizing** (to confirm with load tests): 8 vCPU, 16 GB RAM, NVMe SSD sized for recording retention. Comfortably 100+ concurrent calls with some Opus transcoding and fax.

**File storage**

- All file reads and writes go through a `Storage` behaviour in Elixir with two backends: local disk (version 1) and generic S3 (later, for Garage, SeaweedFS, Hetzner or Backblaze object storage). Switching is a config change.
- Paths are prefixed per tenant; downloads use signed, short-lived URLs served by the app.

**Backups and recovery**

- PostgreSQL: pgBackRest with point-in-time recovery, copied off the server.
- Files: restic to another server or an S3 bucket, at least nightly.
- Carrier failover: carriers send calls to a backup number or voicemail when the server does not answer.
- A restore playbook rebuilds the server on fresh hardware from Ansible plus the latest backups, tested in the lab with the time recorded.

**External monitoring (HetrixTools)**

- `GET /health` (public): HTTP 200 with `{"status":"ok"}`, or 503 with `degraded` or `down`. No details exposed.
- `GET /health/details` (token required): status per component: Kamailio, FreeSWITCH, PostgreSQL, disk space, trunk registrations, Oban backlog, certificate expiry.
- Checks run every 10 seconds in the background; the endpoint returns the cached result, so scraping is cheap.
- HetrixTools watches `/health` plus TCP port checks on 5061 and 443. If the server or the app dies, HetrixTools alerts, which covers the case where Q-PBX cannot report its own failure.

**NAT handling**

- **Signaling:** Kamailio `nathelper` detects NATed clients, stores their real public address and port, rewrites contacts, and sends OPTIONS keepalives every 20 to 30 seconds.
- **Media:** every call's audio is anchored in FreeSWITCH (no direct media between phones), with RTP auto-adjust so it answers to the address the audio really comes from. This removes most one-way audio problems and is needed anyway for recording, fax and IVRs.
- **TLS on 5061 by default,** so router SIP ALGs cannot rewrite the traffic.
- **Grandstream defaults by provisioning:** TLS transport, NAT keepalive on, random local ports, STUN off.
- **Many phones behind one office IP:** tracked per IP and port; bans start per IP and port, known tenant IPs get higher thresholds, and a whole office IP is never banned automatically without an alert.
- **Mobile app on cellular CGNAT:** TLS over TCP, push wake-up, media through FreeSWITCH. No ICE or TURN in version 1; rtpengine comes with WebRTC later.
- **Carriers:** IP-to-IP, no NAT handling needed.

**Host hardening**

- **AppArmor** (enabled by default on Debian 12) with custom profiles written for Q-PBX, run in complain mode during lab phases and then enforced:
  - FreeSWITCH: read its config, write only recording and fax spool folders, no running other programs (blocks the `system` dialplan app path to a shell).
  - Kamailio: read config, write runtime files, no exec.
  - Document converters (Ghostscript now, LibreOffice when DOCX is added): each in its own strict profile, no network, temp folder only, CPU time and memory limits, because they process files from strangers.
  - Elixir app: may run only the converters, write only its data folders.
- **AppArmor `DENIED` events** raise a security alert in the notification system.
- **systemd hardening:** a dedicated non-root user per service, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `ReadWritePaths` limited to each service's folders, `RestrictAddressFamilies`, `SystemCallFilter=@system-service`, and `CapabilityBoundingSet` limited to `CAP_NET_BIND_SERVICE` (plus `CAP_SYS_NICE` for FreeSWITCH). `MemoryDenyWriteExecute` stays off for the Elixir service because it breaks the BEAM JIT.
- **nftables:** default deny; SIP and RTP open only on the service IP; SSH only from management IPs.
- **Unattended security upgrades** for Debian packages.

**Growth path to HA**

1. Add a second server and stream a PostgreSQL replica to it; enable Patroni with etcd, using a small VM as the third vote.
2. Add keepalived; the service IP becomes the floating IP.
3. Cluster a second Elixir node and add a standby FreeSWITCH node; move file storage to the S3 backend or replicate the folder.

No phone, trunk or customer configuration changes at any step.

## Multi-tenancy, plans and limits

Every tenant is a company with its own SIP domain, and every row in the database carries a `tenant_id`. Isolation is enforced at three layers: Kamailio (domain to tenant), FreeSWITCH (per-tenant contexts served by Elixir), and Postgres (tenant-scoped queries plus row-level security as a safety net).

**Tenant identity**

- Each tenant gets a SIP domain under the platform's wildcard domain, for example `acme.pbx.qfiber.co.il`. Custom tenant domains are not scheduled yet.
- Extension numbers only need to be unique inside a tenant; two tenants can both have extension 101.
- All numbers are stored in E.164 so the product works in any country. Each tenant has number normalization rules (country code, area code, local prefixes), so users dial local formats such as 02-123-4567 and caller IDs show the way they expect.

**Roles**

| Role | Scope | Can do |
| --- | --- | --- |
| Platform admin | All tenants | Create tenants, assign plans, manage carriers, media nodes and global settings |
| Tenant admin | One tenant | Manage users, extensions, routes, IVRs, queues, fax, API keys, webhooks |
| Tenant user | Own extension | Voicemail, call history, recordings, fax inbox, forwarding, DND, devices |

**Plans and limits**

A plan is a named set of limits. The platform admin assigns one plan per tenant and can override any limit for a single tenant. Limits are enforced live, not just in the UI.

| Limit | Enforced at |
| --- | --- |
| Max extensions | Portal and API on create |
| Max concurrent calls (inbound, outbound, total) | Call admission in Elixir before bridging |
| Max queues, IVRs, conferences | Portal and API on create |
| Recording and fax storage (GB) | Upload jobs; oldest-first retention when over |
| Outbound minutes or spend per day/month | Call admission (see Security) |
| Allowed destination classes | Outbound routing (local, mobile, international, premium) |
| API rate limit | API gateway plug |
| Feature flags (fax, CRM, flow builder, recording) | Everywhere the feature is reachable |

Invoicing stays outside Q-PBX. The platform exposes usage per tenant (minutes, channels, storage, fax pages) through the API and a CSV export so it can feed an external billing system.

**Tenant offboarding**

- **Export:** a platform or tenant admin can download the tenant's configuration, CDRs, recordings, voicemail and faxes as an archive.
- **Deletion:** removing a tenant deletes its data and files after a grace period (30 days by default), and the deletion is written to the audit log.

## Call features

These are the call features Q-PBX will have. Queues, conferencing and paging come after 1.0; everything else here is in 1.0. Every feature is configurable from the portal and the API, and emits events.

**Core calling**

- **Extensions:** SIP credentials, caller ID (internal and external), multiple devices per extension, DND, call waiting, follow-me, unconditional/busy/no-answer forwarding.
- **Trunks:** platform-level carrier trunks (shared) and tenant-owned trunks (bring your own carrier), registration or IP auth, codec preferences, T.38 flag, max channels.
  - **Several addresses per trunk** (IPs, host names or DNS SRV), because carriers give one, two or four signalling addresses: calls from any of them are accepted; outbound calls go to them by priority (or weight); Kamailio pings each one with SIP OPTIONS, stops using one that does not answer, and brings it back when it answers again. A trunk is "down" (and alerts) only when all of its addresses are.
  - **Caller ID per trunk:** whether a trunk may present the tenant's own number (DID) from another carrier, or must use a number of its own, as each carrier's policy requires.
- **DIDs:** numbers assigned to tenants, each pointing at a destination (extension, ring group, queue, IVR, fax, flow, voicemail, external number).
  - **Backup numbers for incoming calls:** a DID can have alias numbers from other carriers that route exactly like it. Incoming failover between carriers needs the number's own carrier to forward calls to such a backup number when Q-PBX does not answer ("forward on unreachable"); another carrier cannot receive calls for a number it does not hold. The portal documents this per DID.
- **Outbound routes:** pattern-based on E.164, ordered trunk failover, prefix strip/add, per-route destination class.
  - **Failover between carriers:** when the first carrier is down or rejects the call (for example Partner offline), the call goes out through the next carrier on the route (for example Cellcom), still showing the tenant's number where that carrier allows it (see caller ID per trunk).
- **Emergency routes:** a generic route type that bypasses spend limits and always uses a configured trunk. The operator sets the numbers for their country.
- **Codecs:** G.711 a/u, G.722, Opus. G.729 optional.

**Call routing building blocks**

- **IVR / auto attendant:** prompts (uploaded recordings, plus the system prompts), digit options, timeout and invalid handling, direct dial to extensions, nested menus. No text-to-speech: a synthetic voice is not wanted for callers (decided 2026-11-28).
  - **Visual call-flow editor (in 1.0, phase 4):** each DID's routing (time conditions, IVR menus and their options, ring groups, voicemail) shown as a diagram that can be edited by drag and drop, next to the forms. Built on the same LiveView canvas that the phase 8 flow builder extends.
- **Time conditions:** weekly schedules per tenant time zone, holiday calendars, manual override toggle ("office closed now").
- **Ring groups:** ring all, sequential, round robin; per-member timeouts; external numbers as members; final destination on no answer.
- **Queues (ACD):** strategies (longest idle, round robin, ring all, fewest calls), agent login/logout and pause with reasons, music on hold, position and estimated wait announcements, max wait and overflow destination, wrap-up time, live wallboard in the portal.

**Recording and CDR**

- Recording policy per tenant, extension, queue or route: always, never, or on demand (feature code or API).
- Recordings stored through the storage layer as Opus or MP3, playable and downloadable in the portal, retention per plan.
- CDRs written for every call leg with tenant, direction, caller, callee, disposition, durations, recording and trunk used; searchable and exportable.

**Voicemail**

- Per-extension mailbox with PIN, greetings (unavailable, busy, temporary), voicemail-to-email with audio attached, web playback, and optional transcription later.

**Conferencing and paging**

- **Conference rooms:** PIN for participants and moderators, mute controls, recording, join/leave announcements, live participant list in the portal and API.
- **Paging and intercom:** paging groups to Grandstream phones (auto-answer), one-way and two-way intercom by feature code.

**Feature codes**

A default set (voicemail, DND toggle, forwarding, call pickup, park/retrieve, queue login/logout, recording on demand), editable per tenant.

**Busy lamps and indicators**

BLF keys, call parking slots and the voicemail indicator work on Grandstream phones and in Meow. How they work is described under Architecture.

## Fax

Fax runs on FreeSWITCH `mod_spandsp`, with Elixir owning the jobs, retries, storage and delivery. It supports all four paths: inbound to email, outbound from email/web/API, T.38 for ATAs, and T.38 or G.711 to carriers.

**Inbound (fax-to-email)**

1. A DID with destination "fax" (or a fax-detect on a voice DID) answers with `rxfax`.
2. The TIFF is converted to PDF, stored, and logged with pages, remote station ID, duration and result.
3. An Oban job emails the PDF to the fax box's recipients and emits `fax.received`.
4. The fax shows in the tenant's fax inbox in the portal and through the API.

**Outbound (email, web, API to fax)**

1. A job is submitted through the portal upload, the API (`POST /v1/faxes`), or email to a per-tenant address such as `+97221234567@fax.acme.pbx.qfiber.co.il` from an allowed sender.
2. PDF and images are converted (DOCX later) to TIFF-F; a cover page template is optional.
3. Oban sends it with `txfax`, retrying on busy, no answer or failure (configurable count and interval).
4. A confirmation goes by email and webhook (`fax.sent`, `fax.failed`) with the transmission report.

**Email-to-fax (after 1.0)**

- Fax-to-email and sending from the portal and API are in 1.0. Sending by email comes later, because it needs its own protection.
- Mail for the fax addresses is received by a small inbound SMTP service on the platform.
- A message is accepted only if the sender is on the fax box's allowed list and passes SPF or DKIM with DMARC alignment, so a forged From address cannot send faxes on a tenant's bill.
- Rejected attempts are logged and repeated ones raise a security alert. Fax calls count against the same spend limits as voice calls.

**T.38 and transport**

- **ATAs and fax machines:** Grandstream HT8xx provisioned with T.38 and fax-safe settings (jitter buffer off, fixed G.711 fallback).
- **Carriers:** per-trunk mode setting: T.38 re-INVITE, T.38 passthrough, or G.711 passthrough when the carrier has no T.38.
- **Gateway mode:** FreeSWITCH can terminate T.38 on one leg and G.711 on the other when the endpoint and the carrier disagree.
- **ECM:** on by default, can be switched off per trunk for problem carriers.

**Fax boxes**

A fax box is a tenant object with its numbers, email recipients, allowed senders, cover page, retention and the users who can see it. Pages count against the plan's fax limit.

## Endpoints

Q-PBX supports three kinds of endpoint: Grandstream phones and ATAs with zero-touch provisioning, the Meow apps on desktop, iOS and Android, and any third-party SIP app.

**Grandstream provisioning**

Provisioning arrives in phase 5. Until then, phones are pointed at Q-PBX by hand or through the provisioning they already use.

- Supported first: GRP26xx and GXP21xx desk phones, WP8xx Wi-Fi phones, HT8xx ATAs. Other brands plug in later as templates.
- A device is registered by MAC address and assigned to an extension (or several lines) in the portal.
- Phones fetch config over HTTPS from `provisioning.pbx.qfiber.co.il/<mac>.xml`, generated on request from the database. No files on disk.
- Security: per-device credentials or client certificates, MAC must be pre-registered, rate-limited, every fetch logged.
- Zero-touch through Grandstream's GDMS redirect service, or DHCP option 66 on the customer LAN.
- Templates per model control BLF keys, line keys, time zone, language, ringtones, firmware version and fax settings for ATAs.
- Changes push to the phone with a SIP NOTIFY (check-sync), so it reloads without a reboot when the model supports it.

**Meow apps (desktop, iOS and Android)**

- Meow, qFiber's existing softphone, is the official app for Q-PBX. Q-PBX does not build its own mobile app.
- Meow stays a separate, proprietary product. It talks to Q-PBX only over SIP and the public API, so the AGPL license of Q-PBX does not touch it.
- Login by QR code from the portal, so users never type SIP credentials.
- Q-PBX supports what Meow already uses: TLS and SRTP, Opus, busy lamps, call parking and the voicemail indicator.
- Mobile wake-up: a sleeping app holds no registration. Kamailio receives the INVITE, holds it, asks the installation's push provider to wake the device, and delivers the call once the app has registered (RFC 8599 push parameters).

**Push providers**

Push is a setting of each Q-PBX installation, behind one `Push` behaviour. The same provider also delivers notification pushes.

| Provider | How it works | Who uses it |
| --- | --- | --- |
| Push gateway | Q-PBX sends a wake-up request to a gateway URL with an API key; the gateway holds the APNs and FCM keys | qFiber's platform, on its own gateway, and other operators who subscribe to it |
| Direct APNs/FCM | Q-PBX sends the pushes itself with the operator's own keys | Operators who publish their own app |
| None | No push; devices stay registered | Desk phones and third-party apps |

- **Gateway as a paid service:** the Meow apps can only be woken with qFiber's push keys, so another Q-PBX operator who wants Meow for their users subscribes to qFiber's push gateway.
- The gateway is a separate qFiber service and is not part of the AGPL code. Q-PBX contains only the client adapter, built from the existing Meow push integration.
- The gateway serves only qFiber today. Before it is sold it needs an API key per operator, usage metering per operator, and rate limits; that work is scheduled later and does not block 1.0.
- The gateway adapter ships in 1.0. The direct adapter is built when an operator needs it.

**Third-party SIP apps**

- The portal shows SIP settings and a QR code in the common provisioning formats (for example Zoiper, Linphone, Acrobits-style).
- Treated like any other device: per-device credentials, visible in the extension's device list, can be revoked.

## API, webhooks, triggers and CRM

The portal and the public API call the same internal modules, so anything a person can do in the portal, code can do too. All of it runs on one event bus inside Elixir.

**REST API**

- Versioned under `/v1`, JSON, documented with OpenAPI 3 and served with an interactive explorer.
- Auth: per-tenant API keys with scopes (read, write, calls, fax, admin) and expiry; OAuth 2 for CRM apps later.
- Resources: tenants (platform only), users, extensions, devices, DIDs, trunks, routes, IVRs, time conditions, ring groups, queues, agents, conferences, fax boxes, faxes, voicemails, recordings, CDRs, webhooks, flows, usage.
- Call control: originate (click-to-call), hang up, transfer, hold, park, start/stop recording, barge/whisper for supervisors.
- Cursor pagination, filtering, idempotency keys on POST, per-key rate limits.
- A WebSocket (Phoenix Channels) streams live events for dashboards and integrations that need real time.

**Webhooks**

- A tenant registers endpoint URLs and picks the event types for each.
- Events: `call.started`, `call.ringing`, `call.answered`, `call.ended`, `call.missed`, `call.transferred`, `recording.ready`, `voicemail.received`, `fax.received`, `fax.sent`, `fax.failed`, `queue.joined`, `queue.abandoned`, `agent.status_changed`, `extension.registered`, `extension.unregistered`, `limit.reached`.
- Delivery through Oban: HMAC-SHA256 signature header, timestamp, unique event ID, exponential backoff for 24 hours, then dead-letter.
- A delivery log in the portal with request, response, retries and a resend button.

**Outbound request safety**

- Webhooks, alert webhooks, flow HTTP actions and CRM calls make the server send requests to addresses a tenant chose, so they are restricted: HTTPS only by default, no private, loopback or link-local addresses (checked after DNS resolution and on every redirect), and limits on response size and time.
- This stops a tenant from using Q-PBX to reach the internal `mod_xml_curl` endpoint, the database or the management network.

**Triggers and the visual flow builder (after 1.0)**

- A flow is a graph: one trigger, optional conditions, one or more actions.
- Triggers: any webhook event, an inbound call on a DID (the flow becomes the call's router), a schedule, or an API call.
- Conditions: caller number or pattern, time condition, queue stats (wait time, agents free), call duration, custom fields from a CRM lookup.
- Actions: route the call (to any destination), play a prompt, collect digits, HTTP request (with the response usable in later steps), send email, send fax, set caller ID name, start recording, notify via webhook, wait.
- Edited in a LiveView canvas, stored as versioned JSON, executed by a supervised Elixir process per run with a full run log.
- Examples: missed call from a VIP number sends an email to the manager; queue wait over 60 seconds sends calls to overflow; after hours, calls go through a CRM lookup and on to the on-call engineer.

**CRM integrations (after 1.0)**

- A common adapter behaviour: contact lookup by number (screen pop and caller name), log a call with recording link, click-to-call from the CRM.
- First adapter is still to be chosen (HubSpot, Zoho or Odoo); the others follow the same behaviour.
- Credentials stored encrypted per tenant.

## Notifications and alerts

One notification service turns events from the bus into email, alert webhooks, mobile push and in-portal notifications. Rules decide who gets what, at what severity, and how often. Every alert has a state (open, acknowledged, resolved), so people also hear when a problem is over.

**Channels**

| Channel | Details | When |
| --- | --- | --- |
| Email | Platform SMTP relay with SPF/DKIM, optional per-tenant SMTP; templates in English and Arabic (RTL); bounce handling | 1.0 |
| Alert webhooks | Signed and retried like event webhooks, as generic JSON | 1.0 |
| In-portal | Notification bell with unread count, live through LiveView | 1.0 |
| Push | In the Meow apps, through the installation's push provider | 1.0 |
| Chat formats | Ready-made webhook formats for Slack, Microsoft Teams, Discord, Telegram and ntfy | After 1.0 |
| Flows | Any alert can be a flow trigger, for custom automation | After 1.0, with the flow builder |

**Alert catalogue**

| Category | Alert | Default audience | Severity |
| --- | --- | --- | --- |
| Security | SIP attack detected (flood, scanner, mass bans) | Platform admins; the tenant too if its domain is targeted | Critical |
| Security | Brute force on an extension or portal account | Tenant admin, platform admins | Warning |
| Security | Unusual activity: international spike, calls at odd hours, new destination country, spend velocity | Tenant admin, platform admins | Critical |
| Security | Outbound calls blocked by a fraud rule | Tenant admin | Critical |
| Security | Portal login from a new IP or failed 2FA | The user | Warning |
| Health | Service crash or crash loop (FreeSWITCH, Kamailio, Elixir node or process) | Platform admins | Critical |
| Health | Failover happened | Platform admins | Critical |
| Health | Trunk down or registration failed | Platform admins (shared trunk) or tenant admin (own trunk) | Critical |
| Health | Call quality degraded (MOS, jitter, packet loss) | Platform admins | Warning |
| Health | Disk or storage near full, database replication lag, backup failed, certificate expiring | Platform admins | Warning |
| Usage | Minutes threshold reached, with minutes remaining | Tenant admin, billing contact | Info, then Warning at 90% |
| Usage | Limit reached (minutes, channels, storage, fax pages) | Tenant admin, billing contact | Critical |
| Usage | Monthly usage summary | Tenant admin, billing contact | Info |
| Operations | Phone or trunk offline for longer than a set time | Tenant admin | Warning |
| Operations | Queue SLA breached or abandon rate too high | Queue supervisors | Warning |
| Operations | Webhook endpoint failing (moved to dead-letter) | Tenant admin | Warning |
| Personal | Missed call, voicemail, fax received or failed | The user | Info |

**Usage threshold alerts**

- Thresholds are set per plan (default 50%, 80%, 90%, 100%) and can be overridden per tenant.
- Each threshold fires once per billing period and resets when the period resets.
- The message gives minutes used, minutes remaining, percentage, period end date, and a projected run-out date based on the daily average.
- At 100% it states what happens next (outbound blocked or allowed with overage, as the plan says) and that emergency routes still work.
- The same thresholds apply to fax pages and storage.

**Rules and preferences**

- Three severities: info, warning, critical.
- Each role has default subscriptions. Each user picks channels per alert category, and tenant admins can add shared recipients (for example `it@` and `billing@`).
- Platform admins can mark alerts as mandatory (security and critical health) so they cannot be switched off.
- Quiet hours per user, which critical alerts bypass, and, after 1.0, a digest mode (hourly or daily) for info alerts.
- Deduplication and throttling: repeats of the same alert within a window are grouped ("37 more since 14:02"), and each recipient has a rate cap.
- Escalation (after 1.0): a critical alert not acknowledged within 15 minutes (configurable) goes to the next contact.
- Acknowledge from the email link, the portal or the API. Resolved alerts send a short "back to normal" message.

**Alert webhooks and API**

- Event types: `alert.raised`, `alert.acknowledged`, `alert.resolved`, `usage.threshold_reached`.
- Payload: alert ID, key, category, severity, tenant, title, message, structured data, time, and a link to the portal.
- A platform-level alert webhook for operators, compatible with Alertmanager, PagerDuty and Opsgenie style receivers.
- API: list, filter, acknowledge and resolve alerts; read and update preferences; send a test notification.

**How crashes are detected**

- Elixir supervisors and telemetry report process crashes and restart loops.
- Heartbeats check FreeSWITCH (event socket) and Kamailio (SIP OPTIONS and JSON-RPC) every few seconds.
- A small host check inside the Elixir app covers disks, memory and certificates. Prometheus and Alertmanager are added with the second server, not before.
- HetrixTools checks the /health endpoint and SIP/HTTPS ports from outside, and alerts if the server or app is down, so a crash of the notifier is never silent.

**Implementation**

- A `Notifications` context with Oban queues per channel, Swoosh for email, HEEx templates per locale, and a delivery log with a resend button.
- Tables: `alerts`, `alert_rules`, `notification_preferences`, `notification_templates`, `notifications`, `notification_deliveries`, `usage_thresholds`.

## Security and anti-fraud

Toll fraud is the biggest financial risk for a hosted PBX, so spend limits and destination controls are part of call admission from phase 2, before the first tenant goes live.

**SIP edge (Kamailio)**

- `pike` flood detection and per-IP rate limits on REGISTER and INVITE.
- Automatic bans after repeated auth failures, synced to nftables on the edge nodes; allow lists per tenant.
- Scanner fingerprints blocked (known user agents such as sipvicious and friendlyscanner).
- Only TLS (5061) and UDP/TCP 5060 exposed; RTP range firewalled to media nodes.
- Optional per-tenant IP restrictions for extensions.

**Call admission (Elixir, before any outbound bridge)**

- Destination class check against the tenant's allowed classes (local, mobile, international, premium).
- Per-extension and per-tenant concurrent call caps.
- Minute caps per destination class (local, mobile, international, premium) per hour, day and month, with a hard block and a `limit.reached` webhook; a platform-managed list of high-cost prefixes counts as premium and is blocked unless the plan allows it. Money-based spend caps (with a rate table) only later, if operators need them.
- Velocity rules: sudden spikes in international calls or calls at unusual hours alert the tenant and platform admins, and can auto-block.
- Emergency routes skip spend limits but are still logged.

**Credentials and data**

- SIP passwords generated (at least 20 characters), never shown again after creation; per-device credentials.
- Portal: Argon2 password hashing, TOTP 2FA (required for platform admins), session expiry, audit log of every admin change.
- API keys hashed at rest, scoped, expirable, shown once.
- TLS for SIP and HTTPS everywhere; SRTP for the mobile app and supported phones.
- Secrets (carrier passwords, CRM tokens) encrypted with Cloak and a key outside the database.
- Recordings and faxes stored under per-tenant paths and signed, short-lived download URLs.

**Security baseline (added 2026-11-27)**

These apply to every phase; `docs/STATUS.md` ("Security plan") tracks when each part lands.

- **Database:** tenant isolation enforced by row-level security on every tenant request, not
  only by query filters; the app connects as a non-superuser that cannot change the schema
  (migrations run as a separate owner role); the audit log is append-only for the app; every
  input is validated at the boundary (changesets), queries are parameterized, and output is
  escaped (HEEx); Kamailio gets a read-only role on a narrow view.
- **Login:** 2FA required for platform admins and tenant admins (optional for tenant users);
  login, setup and password pages protected by rate limits (per client IP: 5 failures block
  for 1 hour, 5 more block for 24 hours), the real client IP taken only from nginx and, behind
  a CDN, only from that CDN's header (Cloudflare `CF-Connecting-IP`, Imperva
  `Incap-Client-IP`, or a configured header) when the request comes from its ranges, and a
  CAPTCHA or proof-of-work challenge chosen per installation: a built-in, self-hosted
  proof of work (the default, no outside service), Friendly Captcha, Cloudflare Turnstile,
  Captcha.eu, or none.
- **Web application firewall:** nginx can load ModSecurity with the operator's own rules.
- **TLS everywhere** a network is crossed: HTTPS with HSTS for the portal, API and
  provisioning; SIP over TLS (5061) with SRTP is the default for phones and apps and what
  provisioning sets up, while plain SIP on 5060 stays open to phones and trunks that need it
  (most carriers use 5060); TLS for SMTP with credentials,
  outbound webhooks and CRM calls; TLS or an encrypted tunnel between servers once there is
  more than one. Plain protocols stay only on localhost.
- **Sessions:** checked server-side on every request and LiveView event; ended within
  15 minutes of inactivity and after at most 12 hours; revoked instantly (all of a user's
  sessions and live connections) when their password, 2FA or role changes or an admin
  revokes them. API keys are checked on every request and revocable instantly.
- **Encryption at rest:** secrets and sensitive fields encrypted with Cloak; the master key
  comes from a key provider: a local file by default, or AWS KMS for installations that want
  the key off the server. Backups are encrypted, including the server's secrets file, whose
  backup password is kept off the server. Full-disk encryption (LUKS) is a later option.
- **Recordings, voicemail and faxes** are encrypted at rest (a data key per file, wrapped by
  the master key) and decrypted only while streamed to an authorized user.
- **Temporary data** (media being recorded, uploads, document conversion) lives only in
  private, per-service locations in memory (tmpfs), never in a shared `/tmp`, and is removed
  as soon as it is encrypted or processed.
- **Least privilege:** every service runs as its own non-root user under systemd hardening and
  an AppArmor profile (enforced from phase 4); root is used only by systemd, the package
  manager and Ansible.

**Firewall allow and block lists (synced across servers)**

- Managed in the portal and API at two levels: platform-wide (management IPs, carriers, monitoring such as HetrixTools) and per tenant (office IPs, allowed for that tenant's SIP traffic).
- PostgreSQL is the source of truth. Every entry has a scope (SSH, SIP, HTTPS, all), an optional expiry, a reason and an author, and every change is audited.
- The `qpbx_firewall` module applies entries to named nftables sets (atomic element updates, no full reload) and to Kamailio's in-memory tables.
- **Propagation:** a change is broadcast to every server in the cluster at once, and each server also reconciles against the database every 60 seconds, so a server that was offline or restarted catches up on its own.
- Automatic bans from one server are shared too: an attacker banned on one node is banned on all of them, with a TTL.
- The allowlist always wins over automatic bans, so a known office or carrier is never auto-banned.
- Management IPs are protected: removing the last management IP is refused, so nobody can lock themselves out.
- The current nftables state is also written to disk, so the firewall survives a reboot or an Elixir crash with the last known rules.
- On a single server the same mechanism runs with one node; adding servers needs no change.

**Firewall helper**

The Elixir app runs without root, so it never edits nftables itself. A tiny separate service, `qpbx-fwd`, holds the one capability needed (`CAP_NET_ADMIN`) and accepts only three commands over a local Unix socket: add an address to a named set, remove one, and replace a set. It validates every address and cannot change rules or chains, so a compromised app can alter list entries but cannot rewrite the firewall.

## Data model

The model is organized into Phoenix contexts; every table except the platform ones carries `tenant_id`, UUID primary keys, and `inserted_at` / `updated_at`. Routing targets use one polymorphic pair, `destination_type` + `destination_id`, so any DID, IVR option or timeout can point at any destination.

| Context | Tables | Key fields and notes |
| --- | --- | --- |
| Platform | `plans`, `tenants`, `platform_admins`, `carriers`, `media_nodes` | Plan limits as typed columns plus a JSONB `features`; tenant has `sip_domain`, `timezone`, `locale`, `plan_id`, `limit_overrides` |
| Accounts | `users`, `user_roles`, `api_keys`, `audit_logs` | Role per tenant; API key stores hash, scopes, expiry, last used |
| Telephony | `extensions`, `devices`, `sip_credentials`, `dids`, `trunks`, `outbound_routes`, `route_trunks`, `emergency_routes` | `devices` has `mac`, `model`, `template_id`, `push_platform, push_token`; `trunks` has `fax_mode` (t38, t38\_passthrough, g711) |
| Routing | `ivrs`, `ivr_options`, `time_conditions`, `schedules`, `holidays`, `ring_groups`, `ring_group_members` | Each option and fallback uses `destination_type` + `destination_id` |
| Queues | `queues`, `queue_agents`, `agent_sessions`, `queue_calls` | Agent state and pause reasons; `queue_calls` feeds wait and abandon stats |
| Media | `prompts`, `moh_classes`, `recordings`, `recording_policies` | Files go through the storage layer; tables store the file key, duration, size, retention date |
| Voicemail | `mailboxes`, `voicemails`, `greetings` | Read/unread, folder, email recipients |
| Conferencing | `conferences`, `paging_groups`, `paging_group_members` | PINs hashed |
| Fax | `fax_boxes`, `fax_box_numbers`, `faxes` | `faxes` has direction, status, pages, remote ID, attempts, error, file keys (PDF and TIFF) |
| Provisioning | `device_templates`, `provisioning_logs` | Template per vendor and model with variables |
| Integrations | `webhooks`, `webhook_deliveries`, `flows`, `flow_versions`, `flow_runs`, `crm_connections` | Deliveries keep request, response code, attempt count; flow versions are immutable JSON |
| Reporting | `cdrs`, `usage_daily` | `cdrs` is one indexed table (partition by month only once it grows large); `usage_daily` rolled up per tenant for limits and export |
| Platform services | firewall\_entries, number\_rules, platform\_settings, plus the notification tables listed under Notifications | Firewall lists with scope and expiry; per-tenant number normalization; the installation's push provider settings |

**How FreeSWITCH and Kamailio read it**

- FreeSWITCH never reads Postgres directly. `mod_xml_curl` calls the Elixir app for dialplan and configuration, and Elixir answers from an ETS cache invalidated on every change, so lookups stay in the microsecond range.
- Kamailio reads SIP credential hashes, tenant domains, trunk IPs and bans from a small replicated set of tables (or an HTTP API through `http_async_client`) and keeps them in memory with `htable`.
- CDRs and call events arrive through the FreeSWITCH event socket, so Elixir writes them in batches.

## Build phases and acceptance criteria

Version 1.0 is phases 1 to 4 and ends with one real tenant migrated from FreePBX and running in production. Phases 5 to 11 are built one at a time after that. A phase is done only when its criteria pass on the lab setup (one Debian 12 server with the full stack, a Grandstream phone, an HT8xx with a fax machine, Meow on desktop and mobile, and one real carrier trunk) and its automated call tests pass in CI.

**Automated call testing**

- SIPp scenarios run in CI against a real Kamailio and FreeSWITCH: register, internal call, inbound DID, outbound call with limits, transfer, voicemail, IVR digits, fax send and receive.
- Every call feature lands with its SIPp scenario. This is how call behaviour is verified without real phones.
- A load test before go-live confirms the sizing estimate.

1. **Foundation**
   - One Mix project `qfiber/q-pbx` with boundary checks, CI building the FreeSWITCH and app packages, Ansible roles, single-server lab, certificates (wildcard and per-hostname modes), health endpoint.
   - Project docs (`docs/DEVELOPING.md`, `docs/STATUS.md`, `docs/DECISIONS.md`, a `README.md` per module) and the CI doc check; firewall module and helper.
   - Tenants, plans, users, roles, 2FA, audit log, English and Arabic RTL portal shell.
   - A minimal SMTP mailer for account setup links (the rest of notifications stays in phase 3), plus a CLI command that prints a setup link.
   - *Done when:* a platform admin creates a tenant with a plan, a tenant admin logs in with 2FA in either language, and an allowlist change reaches nftables through the helper.
2. **Core calling and protection**
   - First, the design spike on busy lamps, presence and voicemail indicators through Kamailio, proven with a Grandstream phone and Meow.
   - Kamailio authentication against Postgres, Elixir call control over the event socket, ETS cache, fallback dialplan, extensions, devices, trunks (IP and registration), DIDs, number normalization, outbound routes, emergency routes, voicemail, CDRs.
   - Protection before any real tenant: concurrent call, destination class, spend and minute limits, velocity rules, edge bans and rate limits.
   - Backups with pgBackRest and restic, and one tested restore onto a fresh server.
   - *Done when:* two tenants with the same extension numbers call internally and externally with no crossover, changes apply without a reload, a simulated fraud burst is blocked automatically, busy lamps and voicemail lights work, and the restore succeeds within a measured time.
3. **API, webhooks and notifications**
   - `/v1` REST with OpenAPI, API keys, event bus, signed webhooks with retries and outbound request safety, WebSocket event stream, click-to-call.
   - Notification service: email, generic alert webhook and in-portal (push joins in phase 4); preferences and throttling; usage threshold, security and health alerts.
   - *Done when:* every resource so far is manageable through the API, `call.*` webhooks arrive signed within 1 second, a tenant crossing 80% of its minutes gets the email and the alert webhook with minutes remaining, and a webhook aimed at an internal address is refused.
4. **Routing, recording, basic fax, Meow and migration (the 1.0 release)**
   - IVR, time conditions, holidays, ring groups, feature codes, parking, recording policies and file storage.
   - Visual drag-and-drop call-flow editor for each DID's routing (the canvas the phase 8 flow builder extends).
   - Fax boxes, fax-to-email, sending from the portal and API, T.38 modes per trunk.
   - Meow: QR login and mobile wake-up through the push gateway adapter.
   - FreePBX 17 importer: extensions, DIDs, ring groups, IVRs, voicemail boxes and greetings.
   - AppArmor profiles moved to enforce mode; load test.
   - *Done when:* a full call path (DID, time condition, IVR, ring group, recording) works and appears correctly in CDRs and webhooks, 20 consecutive 5-page faxes each way succeed, a Meow mobile app killed in the background rings within 3 seconds, and one real tenant imported from FreePBX has run in production for two weeks without a critical alert.
5. **Grandstream provisioning**
   - Device templates, HTTPS provisioning, GDMS zero-touch, HT8xx fax templates, QR provisioning for third-party apps.
   - *Done when:* a factory-reset Grandstream phone provisions itself with no manual steps.
6. **Queues, conferencing and paging**
   - ACD queues with agents, wallboard and stats; conference rooms; paging and intercom.
   - *Done when:* a queue with agents, overflow and wait announcements works and its stats match the CDRs.
7. **Email-to-fax and fax extras**
   - Inbound SMTP with sender checks, cover pages, DOCX conversion in its sandbox.
   - *Done when:* an allowed sender's PDF is faxed and a forged sender is rejected.
8. **Flows, CRM and alert extras**
   - Visual flow builder and runner, first CRM adapter, chat alert formats, digests, escalation.
   - *Done when:* the example flows run end to end and a CRM logs a call with its recording link.
9. **High availability**
   - Second server and witness, Patroni, keepalived, S3 file storage, Prometheus.
   - *Done when:* stopping the active server restores service on the standby within 30 seconds with no change on any phone or trunk.
10. **Reseller tier**
   - A reseller level between the platform and tenants: the platform admin creates resellers, a reseller manages its own tenants and their users, and the platform admin keeps access to everything. Design to be written and approved before this phase starts.
   - *Done when:* to be defined with the design.
11. **Billing and invoicing** (after 1.0; spec to be written and approved first)
   - Rates per destination (the rate table also allows money-based fraud caps), charges per client from the CDRs: the DIDs each client holds, their external (billable) minutes, recurring fees; invoices with call details, generated and emailed automatically each period.
   - *Done when:* to be defined with the spec.

The order after 1.0 can change with what paying tenants ask for first. Direct APNs/FCM push and custom tenant domains are built when an operator needs them.

## Open questions and deferred items

**Open questions**

- [ ] Which SIP carriers will Q-PBX use first, and which of them support T.38? This sets the default fax mode per trunk.
- [ ] Which client migrates first? (The importer targets FreePBX 17, the version in production.)
- [ ] Push gateway as a paid service: the pricing model (per operator, per device or per push), to be decided later. The gateway serves only qFiber today; support for other operators (keys, metering, rate limits) is built later, before it is sold.
- [x] Should outside contributors sign a contributor agreement, so qFiber can also offer Q-PBX under commercial terms next to the AGPL? **Yes (2026-11-27):** AGPL-3.0 plus a CLA (`CLA.md`), so qFiber can dual-license.
- [ ] Does voicemail and call transcription belong in a later phase, and should it run on a local model or an external service?
- [ ] Do tenants need their own branding (logo and colours on the portal)?
- [ ] Which CRM adapter comes first in phase 8: HubSpot, Zoho or Odoo?

**Not scheduled yet**

- Arabic voice prompts (recorded or TTS).
- WebRTC browser softphone.
- More phone brands (Yealink, Fanvil).
- SMS and WhatsApp messaging.
- Custom tenant domains.
- Active/active clustering and geo-redundancy beyond 500 extensions.
