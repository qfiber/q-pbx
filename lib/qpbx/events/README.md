# Events (`QPBX.Events`)

**Purpose:** the internal event bus: typed, versioned event structs on Phoenix.PubSub
(reaches every node in the cluster).

**Public API:** `publish(event_struct)`, `subscribe(EventModule)`. Subscribers receive
`{:event, struct}`. Each event module defines `topic/0` and a `version` field.

**Events defined:**
| Struct | Topic | Version | Fields | Emitted by |
| --- | --- | --- | --- | --- |
| `QPBX.Events.FirewallChanged` | `firewall` | 1 | `at`, `reason` | `QPBX.Firewall` |
| `QPBX.Events.SessionsRevoked` | `sessions` | 1 | `session_ids`, `at` | `QPBX.Core` (sessions) |
| `QPBX.Events.SipCredentialsChanged` | `sip_credentials` | 1 | `tenant_id`, `at` | `QPBX.Core` |
| `QPBX.Events.TenantsChanged` | `tenants` | 1 | `tenant_id`, `at` | `QPBX.Core` |
| `QPBX.Events.CallState` | `call_state` | 1 | `tenant_id`, `domain`, `extension`, `peer`, `call_id`, `state` (early, confirmed, terminated), `direction` (initiator, recipient), `at` | `QPBX.Telephony` (busy lamps) |
| `QPBX.Events.CallEvent` | `calls` | 1 | `type` (started, ringing, answered, transferred, ended, missed), `tenant_id`, `call_id`, `direction`, `from`, `from_name`, `to`, `extension_id` (the calling extension), `target` (`%{type: extension, extension_id, number}`, `%{type: external, number}` or `%{type: other}`), `disposition`, `cause`, `duration`, `billsec` (ended), `extension_ids` (missed), `at` | `QPBX.Telephony` (the call process, in order) |
| `QPBX.Events.ExtensionRegistration` | `registrations` | 1 | `type` (registered, unregistered), `reason` (unregister, expired), `tenant_id`, `extension_id`, `extension`, `device` (the login), `contact`, `user_agent`, `at` | `QPBX.Edge` (Kamailio's reports) |
| `QPBX.Events.LimitReached` | `limits` | 1 | `tenant_id`, `limit`, `detail`, `at` | `QPBX.Telephony` (a call refused by admission) |
| `QPBX.Events.VoicemailReceived` | `voicemail` | 1 | `tenant_id`, `voicemail_id`, `extension_id`, `caller_number`, `caller_name`, `duration`, `at` | `QPBX.Telephony` (a message was left) |
| `QPBX.Events.VoicemailChanged` | `mwi` | 1 | `tenant_id`, `extension_id`, `new`, `saved`, `at` | `QPBX.Telephony` (a mailbox's counts changed) |
| `QPBX.Events.FraudAlert` | `fraud` | 1 | `tenant_id`, `rule`, `detail`, `blocked`, `at` | `QPBX.Telephony` (a velocity rule fired) |
| `QPBX.Events.EdgeAlert` | `edge_alerts` | 1 | `ip`, `reason`, `at` | `QPBX.Edge` (an office IP would have been banned) |
| `QPBX.Events.ConfigChanged` | `config` | 1 | `tenant_id` (nil: platform), `kind`, `at` | `QPBX.Core` (telephony configuration and plans) |

**Gotchas:** bump `version` and keep old fields when an event's shape changes; webhooks
(phase 3) will expose these structs.
