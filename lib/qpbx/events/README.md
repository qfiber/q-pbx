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
| `QPBX.Events.ConfigChanged` | `config` | 1 | `tenant_id` (nil: platform), `kind`, `at` | `QPBX.Core` (telephony configuration) |

**Gotchas:** bump `version` and keep old fields when an event's shape changes; webhooks
(phase 3) will expose these structs.
