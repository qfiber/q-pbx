# Integrations (`QPBX.Integrations`)

**Purpose:** everything that reaches out to addresses tenants choose: the one outbound HTTP
client and webhooks (flows and CRM adapters come later).

**Public API:** `request/3` (`QPBX.Integrations.OutboundHTTP`): `request(method, url, opts)` →
`{:ok, %{status, headers, body}}` for any HTTP status, or `{:error, reason}` (`:bad_url`,
`:https_required`, `{:blocked_address, ip}`, `:nxdomain`, `:timeout`, `:too_large`,
`:too_many_redirects`, `{:connect, reason}`, `{:http, reason}`). Options: `headers`, `body`,
`timeout` (whole exchange, default 10 s), `connect_timeout` (5 s), `max_body` (1 MB),
`max_redirects` (3). Exported: `QPBX.Integrations.Address` (`public?/1`, `allowed?/2`,
`in_cidr?/2`).

**What it guarantees:**
- HTTPS only, always (no setting turns plain HTTP on); no credentials in the URL.
- The host is resolved here (both families) and every answer must be a public address; one
  inside answer refuses the request. Inside: this host, private and shared networks,
  link-local (cloud metadata), multicast, reserved and documentation ranges, and every IPv6
  form carrying an IPv4 address (mapped, compatible, NAT64, 6to4, Teredo). Spellings such as
  `2130706433` or `0x7f.1` are parsed to the address they mean before the check.
- The connection goes to the checked address (Mint with `hostname:`), so the name is never
  resolved twice; Host, SNI and certificate verification use the name (system CA store).
- Each redirect is checked from the start; 303, and 301/302 after a POST, continue as GET
  without a body; `authorization` is dropped when the host changes.

**Installation settings** (`config :qpbx, QPBX.Integrations`; inventory
`qpbx_outbound_allow_cidrs`, `qpbx_outbound_ca_file`): `allow_cidrs` (inside networks the
operator trusts, such as a lab receiver; default none), `ca_file` (extra certificate
authorities, PEM, trusted next to the system's; default none). Tenants cannot change either.

**Telemetry:** `[:qpbx, :outbound, :request]` (`duration`; metadata `host`, `result`: the
status or the error reason).

**Webhooks** (`QPBX.Integrations.Webhooks`; tables `webhook_endpoints`, `webhook_deliveries`,
row-level security):
- API (tenant scope, audited): `webhook_event_types/0`, `list_webhooks/1`, `get_webhook/2`,
  `change_webhook/2`, `create_webhook/3` (`{:ok, endpoint, secret}`), `update_webhook/4`,
  `delete_webhook/3`, `rotate_webhook_secret/3` (`{:ok, endpoint, secret}`),
  `list_webhook_deliveries/4` (newest first, `before: {inserted_at, id}`),
  `get_webhook_delivery/2`, `resend_webhook_delivery/3` (a new delivery of the same event id).
- An endpoint: HTTPS URL (refused at save when it resolves inside, and checked again on every
  delivery), event types, description, enabled, a secret (`whsec_...`, Cloak-encrypted, shown
  on creation and rotation only).
- Event types (`Webhooks.Event`): `call.started|ringing|answered|transferred|ended|missed`,
  `extension.registered|unregistered`, `voicemail.received`, `limit.reached`. Body:
  `{"id", "type", "version", "created_at", "tenant_id", "data"}`; `id` is the same for every
  endpoint and resend of one event.
- `Webhooks.Dispatcher` (started by the application; off in tests) subscribes to the bus and
  calls `Webhooks.dispatch/1`: a delivery row and an Oban job per endpoint in one transaction.
- `Webhooks.Worker` (queue `webhooks`, 10 at once): POST with `x-qpbx-event-id`,
  `x-qpbx-event-type`, `x-qpbx-timestamp`, `x-qpbx-signature: v1=<hex HMAC-SHA256 of
  "<timestamp>.<body>">` (`Webhooks.Signature`: `sign/3`, `valid?/6`, 5-minute tolerance);
  2xx delivers; otherwise retried after 30 s, doubling to at most 6 h apart, until 24 hours
  have passed, then dead (`WebhookDeadLettered`). Every attempt is logged on the delivery
  (time, status or error, duration, the answer's first 2 KB). Disabled or removed endpoints
  are not sent to.
- `Webhooks.Prune` (Oban cron, 03:17 daily) deletes deliveries older than 30 days.

**Events:** emits `WebhookDeadLettered`; consumes `CallEvent`, `ExtensionRegistration`,
`VoicemailReceived`, `LimitReached` (webhooks).

**Gotchas:**
- Tests pass `resolver:` (a fun from host to address tuples) and `cacerts:`; never use them in
  application code.
- HTTP/1.1 only, one connection per request (no pool): these are low-volume calls.
- Webhook deliveries run in parallel, so they can arrive out of order (and a retry arrives
  later than newer events): receivers order by `created_at` and drop repeats by `id`.
