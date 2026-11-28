# Integrations (`QPBX.Integrations`)

**Purpose:** everything that reaches out to addresses tenants choose. So far the one
outbound HTTP client; webhooks (3-5), flows and CRM adapters come later.

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

**Events:** none emitted or consumed.

**Gotchas:**
- Tests pass `resolver:` (a fun from host to address tuples) and `cacerts:`; never use them in
  application code.
- HTTP/1.1 only, one connection per request (no pool): these are low-volume calls.
