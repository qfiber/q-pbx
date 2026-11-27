# Telephony (`QPBX.Telephony`)

**Purpose:** call control. FreeSWITCH asks for a dialplan (`mod_xml_curl`) on every new call;
the answer parks it under Elixir's control, and one process per call drives it over the
event socket.

**How a call runs:**
1. A phone or carrier sends INVITE to Kamailio, which tags it (`X-QPBX-Source`, `-Tenant`,
   `-Auth-User` or `-Trunk`) and forwards it to FreeSWITCH (127.0.0.1:5080).
2. FreeSWITCH POSTs to `/internal/freeswitch/dialplan` (web area; loopback and FreeSWITCH's
   password only; nginx refuses `/internal/`). `Dialplan.xml/1` answers: `qpbx_call=true`,
   `continue_on_fail=true`, `hangup_after_bridge=false`, `park_timeout=30:NORMAL_TEMPORARY_FAILURE`, park.
   If the app does not answer within 3 s, FreeSWITCH's static dialplan answers 503 (a carrier
   fails over to the number's backup).
3. `ESL.Connection` (one inbound event socket, 127.0.0.1:8021) gets `CHANNEL_PARK`;
   `Calls.dispatch/1` starts a `Call` (DynamicSupervisor, `Registry` by channel UUID).
4. `Call` asks `Router.plan/2` for an action tree and walks it: `bridge` through `sendmsg`,
   then the busy / no answer / failed branch from the bridge's `originate_disposition`. A
   carrier failure (503, timeout, out of order) moves to the next trunk; busy and no answer are
   final. Answered: when the bridge ends the call ends.

**Routing (`Router`, pure):** phone to extension (all its devices, through Kamailio with
`sip_route_uri`); extension features: forward always, do not disturb (busy), call waiting off
(busy while on a call), forward on busy, forward on no answer (after `no_answer_seconds`),
follow-me (its numbers ring after the devices); forwarding loops stop after 5 hops. Phone to
an outside number: the tenant's number rule to E.164, the tenant's own numbers stay inside,
else the first matching outbound route, its trunks in order with `X-QPBX-Trunk-Edge` (Kamailio
fails over across a trunk's addresses), the number rewritten for the carrier, caller ID per
trunk (the extension's outside caller ID or the tenant's first number; `own_number` trunks
their own; the name is the number). Emergency numbers: their platform trunk. Carrier to a
number: the DID in any form (E.164, without +, national), backup numbers as their main
number, a tenant's own trunk only for its numbers; destination extension or an outside number
(shown with the called number); the caller shown nationally.

**Cache (`Cache`, ETS):** each tenant's snapshot (`QPBX.Core.telephony_tenant/1`), the
platform's and the DID index, loaded on first use and all dropped on `ConfigChanged`,
`SipCredentialsChanged` or `TenantsChanged`.

**Public API:** `dialplan_xml/1`, `connected?/0`, `active_calls/0`, `curl_password/0`;
`child_spec/1` (started by the application; the event socket only with `config :qpbx,
QPBX.Telephony, esl: true`, i.e. production).

**Events consumed:** `ConfigChanged`, `SipCredentialsChanged`, `TenantsChanged` (cache).
**Emitted:** none yet (call events and CDRs arrive with 2-8).

**Gotchas:**
- Without `continue_on_fail=true` FreeSWITCH hangs up the caller after a failed bridge, so
  no failover or forwarding could follow.
- An extension is "on a call" from `CHANNEL_BRIDGE` until its call process ends;
  `CHANNEL_EXECUTE_COMPLETE` of a bridge comes only when the bridge is over.
- FreeSWITCH's 503 reaches a carrier as 500 through Kamailio (a proxy must not pass 503
  upstream, RFC 3261 16.7).
- Admission (limits, destination classes, fraud) is 2-6; voicemail on no answer is 2-7.
- Lab check with real calls: `lab/done-when/phase2-calls.py <vm-ip>` (endpoints in
  `lab/tools/sipua_daemon.py`).
