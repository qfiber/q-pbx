<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="priv/static/images/logo-dark.svg">
    <img src="priv/static/images/logo.svg" alt="Q-PBX" width="420">
  </picture>
</p>

# Q-PBX

Q-PBX is a multi-tenant cloud PBX with fax built in. Every feature can be driven through its
API. It uses FreeSWITCH for media and fax and Kamailio at the SIP edge. Everything else is new
code in Elixir and Phoenix, backed by PostgreSQL. We built it to replace FreePBX in our own
cloud PBX service, and we publish it under the AGPL.

> Q-PBX is under active development and is not ready for production yet. Version 1.0 ends
> with a real customer moved over from FreePBX.

## Why another PBX

- **New code, no legacy.** There are no generated config files, no PHP modules and no dialplan
  that grew over twenty years. FreeSWITCH holds no tenant config: it asks the control plane for
  everything, and the control plane answers from memory.
- **Changes apply instantly.** Save an extension, a route or a trunk and the next call uses it.
  There is no "Apply config" button, no reload, and no dropped calls.
- **Built on Elixir.** Every call runs in its own lightweight process. When one call fails,
  that call ends and the rest carry on. The runtime was made for telephone switches, and it
  handles many calls at once without trouble.
- **Multi-tenant from day one.** Tenants are separated at the SIP edge, in FreeSWITCH and in
  the database, where row-level security backs up every query. Two tenants can both have
  extension 101.
- **API first.** Everything you can do in the portal, you can also do with the REST API, and
  both share one permission check. You also get signed webhooks, a live event stream and
  click-to-call.
- **Secure by default.** All SIP goes through Kamailio, which bans brute force and scanners and
  rate-limits floods. FreeSWITCH listens only on localhost. Admins sign in with 2FA, secrets
  are encrypted (the master key can live in AWS KMS), and the firewall is default deny.
  Outbound requests (webhooks) are HTTPS only and never go to internal addresses.
- **Fraud limits built in.** You can cap concurrent calls, minutes and destination classes, and
  sudden bursts of calls get blocked. Emergency numbers always go through.
- **Private.** You run it on your own server. Voicemail is encrypted at rest, and nothing is
  sent anywhere you did not configure.
- **Easy to run.** It installs natively on Debian 12 with Ansible and systemd, without Docker.
  Nightly backups are encrypted, and a tested restore rebuilds a server.

## What works today

**Platform and portal**
- Tenants, plans and per-tenant limits, users and roles, 2FA, and an audit log
- Portal in English and Arabic (full right-to-left)
- Firewall allow and block lists, enforced in nftables and Kamailio
- Health checks, automatic certificates (wildcard or per hostname), nightly encrypted backups
  with point-in-time restore

**Calling**
- Extensions with several devices, forwarding, DND, call waiting and follow-me
- Trunks with IP or registration auth and several addresses each, with failover between
  carriers
- DIDs, outbound routes by number pattern, and emergency routes
- Voicemail with email delivery and message lights, busy lamps (BLF), and call records
- Call admission and fraud protection

**API and events**
- `/v1` REST API with OpenAPI docs, an in-browser explorer, scoped API keys, idempotency and
  rate limits
- Signed webhooks with retries, a delivery log and resend
- WebSocket event stream; click-to-call, transfer and hang up through the API

**Alerts and notifications**
- Alerts by email, by webhook (generic or Alertmanager format) and in the portal, with
  preferences, quiet hours and grouping of repeats
- Alerts for brute force and SIP attacks, logins from a new address, services and trunks going
  down, disk, certificates and backups, usage thresholds, phones going offline, and missed
  calls and voicemail

## What's next

**Version 1.0**
- IVR, time conditions and holidays, ring groups, parking, feature codes, call recording
- A drag-and-drop editor for each number's call flow
- Fax: fax boxes, fax-to-email, sending from the portal and API, T.38 per trunk
- Mobile push wake-up for the softphone app, and a FreePBX 17 importer

**After 1.0** (the order may change)
- Grandstream auto-provisioning
- Queues, conferencing and paging
- Email-to-fax
- A flow builder, CRM integrations and more alert channels
- High availability (active/standby)
- A reseller tier
- Billing

## Documentation

- [`docs/SPEC.md`](docs/SPEC.md): the full product spec
- [`docs/STATUS.md`](docs/STATUS.md): progress, task by task
- [`docs/DEVELOPING.md`](docs/DEVELOPING.md): architecture, commands, running it locally,
  installing a server
- [`docs/DECISIONS.md`](docs/DECISIONS.md): design decisions and why we made them

## License

Copyright (C) 2026 qFiber.

Q-PBX is free software: you can redistribute it and/or modify it under the terms of the GNU
Affero General Public License version 3 as published by the Free Software Foundation (see
`LICENSE`). If you run a modified version for users over a network, you must offer them its
source code.

qFiber also offers Q-PBX under commercial terms. Contributions require the Contributor License
Agreement in `CLA.md`; see `CONTRIBUTING.md`.
