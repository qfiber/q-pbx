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

**Exported schemas** (for the API's records and documents): `Cdr`, `Fraud.Settings`,
`Fraud.Block`, `Voicemail.Mailbox`, `Voicemail.Message`, `Voicemail.Greeting`.

**Public API:** `dialplan_xml/1`, `connected?/0`, `active_calls/0`, `curl_password/0`;
`fraud_settings/0`, `change_fraud_settings/2`, `update_fraud_settings/2`, `list_fraud_blocks/0`,
`lift_fraud_block/2`; call records for tenant admins: `search_cdrs/4` (filters `from`, `to`,
`number`, `direction`, `disposition`, `leg`, `extension` (one extension's calls: its own a-legs
and the legs that rang it, one row per call); `limit`, `offset`, `before: {started_at, id}`
(keyset paging, newest first by time then id)), `stream_cdrs/4` (all matches,
oldest first, inside a transaction), `usage_daily/2`, `cdr_directions/0`; voicemail for tenant admins (scope first): `mailbox/2`, `change_mailbox/2`,
`save_mailbox/4`, `delete_mailbox/3` (rows and files; call it before deleting the extension),
`list_voicemails/2` (`{message, extension_id}`), `voicemail_audio/3`, `save_voicemail/4`,
`delete_voicemail/4` (a last `ext_id` limits each to one extension's mailbox: a tenant user's own), `greetings/2`, `greeting_kinds/0`, `put_greeting/5` (MP3 or WAV by
content, up to 5 MB), `delete_greeting/4`; `voicemail_counts/1` (`%{extension_id => {new,
saved}}`, for the voicemail lights);
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

**Voicemail (`Voicemail`, `VoicemailFlow`, 2-7):** one mailbox per extension (`mailboxes`:
PIN hashed with Argon2, 4 to 10 digits, not all one digit or a run; optional email, audio
attached or not), greetings (`greetings`: unavailable, busy, temporary; the temporary one wins
while it exists) and messages (`voicemails`: caller, duration, folder new or saved); audio in
`QPBX.Storage`, encrypted. An extension's unanswered or busy call ends in
`%{op: :voicemail}` (unless forwarding applies); with an enabled mailbox the call process
answers, plays the greeting (uploaded, or "the person at extension N is not available"), a
tone, and records up to 180 s (MP3, # or 5 s of silence ends it) into `/run/qpbx-media`;
then the recording is encrypted into storage and the plain file removed, also when the caller
hangs up mid-message. Without a mailbox the call ends as before. `*97` from a phone: its own
mailbox behind the PIN (3 tries), the count of new messages, then each message (new first)
with 7 delete, 9 or # keep and next, 5 repeat; a played message becomes saved. Decrypted
copies for playback live in the temporary folder only while they play. Each change of a
mailbox's counts publishes `VoicemailChanged` (voicemail lights); a new message also
`VoicemailReceived` and, with an email address, `QPBX.Notify.deliver_voicemail/1`. Prompts
come from the `qpbx-sounds` package (FreeSWITCH's English "Callie" set, `sound_prefix`).

**Call records (`Cdrs`, `CdrImporter`, 2-8):** FreeSWITCH writes every leg as JSON into the
spool (`mod_json_cdr`, `/var/lib/qpbx/cdr-spool`); `CdrImporter` (with the event socket, so
production only) reads files at least 2 s old every 2 s, up to 500 a round, stores them in one
batch (`cdrs`, one row per leg, unique by leg UUID, so a re-import is harmless) and deletes
them. While the app or Postgres is down the files wait: the spool is the queue. Unreadable
files move to `bad/`. Loopback legs (echo test) are skipped; a leg whose tenant no longer
exists is kept without one. The call process tags the a-leg when routing starts (`export
qpbx_tenant`, `qpbx_caller`, `qpbx_direction`; `set qpbx_destination`; `qpbx_direction=outbound`
when a carrier is tried, also when admission refuses the call); dial legs carry `qpbx_callee` (extension number or E.164) and,
towards carriers, `qpbx_trunk_id`. A b-leg's call is its `originating_leg_uuid`. Outcome:
answered, busy, no_answer, failed. New a-legs roll up into `usage_daily` (calls, answered,
talk seconds per tenant, day in the tenant's time zone, direction). Portal: Calls (search,
CSV export, the last 14 days).

**Busy lamps:** the call process publishes `CallState` for the calling extension (initiator:
early, confirmed) and each extension rung (recipient: early, confirmed, terminated when not
answered there); everything goes terminated when the call ends. The caller is named by
extension number.

**Call events (`Call.Events`):** the call process publishes `CallEvent` at each step, in
order and synchronously: `started` once routed (direction internal, inbound or outbound),
`ringing` on the first `CHANNEL_PROGRESS` or `CHANNEL_PROGRESS_MEDIA` of each dial (the event
socket subscribes to both), `answered` on `CHANNEL_BRIDGE`, `transferred` when a REFER moves
the call, `ended` at hangup (disposition answered, voicemail, busy, no_answer or failed;
cause, duration, billsec from the hangup event), then `missed` when it rang extensions and
nobody answered (calls to carriers are never missed). A call no tenant claimed publishes
nothing. A 302 redirect is not a transfer.

**Click-to-call and live calls (`ClickToCall`, tenant scope):** `originate/4` (scope,
extension id, target, actor; `{:ok, call_id}`): `bgapi originate` rings the extension's devices
(30 s, showing the target) with `qpbx_*` channel variables (tenant, source device, a device
login, destination; no SIP request can set those); answered, the leg parks and `Call` routes it
as that device dialling the target, so admission, records and `call.*` apply; the call id is
the leg's `origination_uuid`. Not answered: FreeSWITCH's failed BACKGROUND_JOB is logged.
`list_live_calls/1` (`Calls.summaries/0`: each call process's summary), `hangup_call/3`
(`uuid_kill`: a hangup message would wait behind the running bridge), `transfer_call/4`
(`uuid_transfer <id> <target> XML public`: the caller's side is re-parked and re-routed, the
other side released). Targets: extension numbers, E.164, feature codes, or local forms through
the tenant's number rule; anything else is refused before FreeSWITCH sees it. Audited.

**Usage alerts (`UsageAlerts`):** after a carrier call's minutes are added, the month's
outbound minutes against `outbound_minutes_per_month`: each threshold (the tenant's, else the
plan's) crossed by that call publishes `UsageThresholdReached` once (minutes to a tenth, the
period end, the run-out at the month's daily average). `UsageAlerts.Summary` (Oban cron, the
1st at 06:00 UTC, queue `calls`) publishes `UsageSummary` per tenant from `usage_daily`.

**Events consumed:** `ConfigChanged`, `SipCredentialsChanged`, `TenantsChanged` (cache).
**Emitted:** `CallState`, `CallEvent`, `UsageThresholdReached`, `UsageSummary`, `LimitReached`, `FraudAlert`, `VoicemailReceived`,
`VoicemailChanged`.

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
- FreeSWITCH runs the applications the call process sends in order; the voicemail flow waits
  only for the last one of each batch (`play_and_get_digits` always ends a batch).
- The call process is split: `Call` (events and routing), `Call.Lamps` (busy lamps),
  `Call.Limits` (admission, minute cap, usage).
- Lab check for call records: `lab/done-when/phase2-cdrs.py <vm-ip>`.
- Lab check for voicemail: `lab/done-when/phase2-voicemail.py <vm-ip>`.
- Lab check with real calls: `lab/done-when/phase2-calls.py <vm-ip>` (endpoints in
  `lab/tools/sipua_daemon.py`).
