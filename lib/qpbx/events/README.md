# Events (`QPBX.Events`)

**Purpose:** the internal event bus: typed, versioned event structs on Phoenix.PubSub
(reaches every node in the cluster).

**Public API:** `publish(event_struct)`, `subscribe(EventModule)`. Subscribers receive
`{:event, struct}`. Each event module defines `topic/0` and a `version` field.

**Events defined:**
| Struct | Topic | Version | Fields | Emitted by |
| --- | --- | --- | --- | --- |
| `QPBX.Events.FirewallChanged` | `firewall` | 1 | `at`, `reason` | `QPBX.Firewall` |

**Gotchas:** bump `version` and keep old fields when an event's shape changes; webhooks
(phase 3) will expose these structs.
