# Edge (`QPBX.Edge`)

**Purpose:** Kamailio integration. Kamailio keeps no configuration of its own: tenant domains
and SIP credential hashes are loaded into its memory (htable) from read-only views in the
`kamailio` database schema (`kamailio.domains`, `kamailio.credentials`), read with the
`qpbx_kamailio` role. Later: bans, trunk addresses, push wake-up, NAT state.

**Public API:** `QPBX.Edge.reload/1` ("credentials" or "domains", over Kamailio's JSON-RPC);
`QPBX.Edge.Reloader` (started by the application).

**Events consumed:** `SipCredentialsChanged` (reload credentials), `TenantsChanged` (reload
domains). **Events emitted:** none.

**Gotchas:** the views are part of Core's migrations (Core owns the tables). A failed reload
is retried 5 times, 5 s apart; a Kamailio restart loads everything from the database.
