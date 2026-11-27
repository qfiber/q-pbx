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
`fraud_settings/0`, `change_fraud_settings/2`, `update_fraud_settings/2`, `list_fraud_blocks/0`,
`lift_fraud_block/2`;
`child_spec/1` (started by the application; the event socket only with `config :qpbx,
QPBX.Telephony, esl: true`, i.e. production).

**Echo test, transfers, redirects:** `*43` (from a phone) bridges to a FreeSWITCH loopback
channel (`loopback/qpbx-echo/public/XML`); `Dialplan` serves that destination only to loopback
channels: answer, a tone prompt of about 5 s, then echo. A blind transfer (REFER) moves the
caller's channel back into the dialplan: the call process sees FreeSWITCH's
`transfer_history` grow on the finished bridge and the next `CHANNEL_PARK` carries the new
destination, which `Router.transfer/3` routes with the same caller (a carrier call stays in
its number's tenant). Attended transfers (REFER with Replaces) are done by FreeSWITCH
itself. A 302 from the far end is followed (`sip_redirect_contact_user_0`), up to 3 times.

**Call admission (`Admission`, 2-6):** when a call starts, the tenant's total and inbound
concurrent caps and the calling extension's own cap; before every bridge to a carrier (each
trunk dial carries `trunk_call: %{e164, class, emergency}`): emergency numbers pass (audited
`call.emergency`); otherwise the destination class must be in the plan's
`allowed_destination_classes` (an empty list allows local, mobile and international, never
premium, i.e. the high-cost prefixes), no fraud block for international or premium, the
outbound concurrent cap, the class's minutes per hour, day and month, the total outbound
minutes per day and month. Admitted calls get `execute_on_answer='sched_hangup +N'` with
the seconds the tightest cap has left. Refusals (`OUTGOING_CALL_BARRED`, 403; a full cap
`NORMAL_CIRCUIT_CONGESTION`, 503, which reaches phones as 500 through Kamailio) are audited
(`call.refused`) and announced (`LimitReached`). Concurrency is counted from live call
processes (`Registry` `QPBX.Telephony.Active`). One admission per destination number, so
carrier failover does not count twice.

**Usage (`Usage`):** outbound talk time per tenant, class and hour (`call_usage`), recorded
when a carrier call's bridge ends; day and month in the tenant's time zone.

**Velocity (`Fraud`):** international and premium attempts per tenant in memory: more than
`international_spike_calls` in 10 minutes, or one in the tenant's quiet hours, raises
`FraudAlert` (audited, once per hour per rule) and, as the settings say, blocks the tenant's
international and premium calls for `block_hours` (`fraud_blocks`). Lifting a block also
clears the attempts that caused it. Settings and blocks: Platform > Fraud protection.

**Busy lamps:** the call process publishes `CallState` for the calling extension (initiator:
early, confirmed) and each extension rung (recipient: early, confirmed, terminated when not
answered there); everything goes terminated when the call ends. The caller is named by
extension number.

**Events consumed:** `ConfigChanged`, `SipCredentialsChanged`, `TenantsChanged` (cache).
**Emitted:** `CallState`, `LimitReached`, `FraudAlert`.

**Gotchas:**
- Without `continue_on_fail=true` FreeSWITCH hangs up the caller after a failed bridge, so
  no failover or forwarding could follow.
- An extension is "on a call" from `CHANNEL_BRIDGE` until its call process ends;
  `CHANNEL_EXECUTE_COMPLETE` of a bridge comes only when the bridge is over.
- FreeSWITCH's 503 reaches a carrier as 500 through Kamailio (a proxy must not pass 503
  upstream, RFC 3261 16.7).
- SRTP from phones (SDES `a=crypto` on RTP/AVP, as Meow sends): FreeSWITCH globals
  `rtp_allow_crypto_in_avp=true` and `rtp_secure_media_inbound=optional`, and the sofia
  profile with `enable-soa=false` (sofia-sip's offer/answer otherwise turns the SRTP answer
  into `m=audio 0`). Calls FreeSWITCH places to phones are plain RTP for now.
- Concurrency and velocity counts are per node (in memory); with two nodes (HA) only the
  active one carries calls.
- Voicemail on no answer is 2-7.
- Lab check with real calls: `lab/done-when/phase2-calls.py <vm-ip>` (endpoints in
  `lab/tools/sipua_daemon.py`).
