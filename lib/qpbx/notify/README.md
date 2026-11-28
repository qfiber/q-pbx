# Notify (`QPBX.Notify`)

**Purpose:** account emails (setup link, new voicemail) and the notification service: alerts,
who hears of them and how (portal bell, email, shared recipients, alert webhooks),
preferences, the delivery log. Mobile push joins in phase 4; alert sources in 3-9.

**Account emails:** `deliver_setup_link(account, url)` (worker `SetupLinkEmail`) and
`deliver_voicemail(vm)` (worker `VoicemailEmail`; the job holds the storage key, never the
audio, decrypted while the email is built). Queue `notify`.

**Alerts** (`QPBX.Notify.Alerts`; tables `alerts`, `alert_rules`, `notification_preferences`,
`alert_channels`, `notifications`, all but `alert_rules` under row-level security):
- `raise_alert(%{kind, key, title, message, tenant_id?, user_id?, data?, category?,
  severity?})`: kinds in `QPBX.Notify.Catalogue` (category, severity, audience). An open
  alert with the same key (per tenant, or platform) is the same alert: the repeat is counted
  (`count`), and recipients hear of repeats at most every 15 minutes ("37 more since 14:02").
  `resolve_alert_key(tenant_id, key)`: the problem went away.
- States: open, acknowledged, resolved. Acknowledging tells webhooks only; resolving tells
  everyone told of the alert ("back to normal").
- People: the kind's audience (`:platform_admins`, `:tenant_admins` of its tenant,
  `:user`); each person's channels per category (`portal`, `email`; default both). A person's
  email carries warning and critical alerts, and usage reports (thresholds, the monthly summary)
  at any severity; other info stays in the portal. Categories platform
  admins made mandatory always reach the defaults. Quiet hours (local hours in the person's
  time zone: their setting, else the tenant's, else UTC) hold back email except for critical
  alerts. At most 20 emails an hour to one address; held-back emails are logged `skipped`
  (`quiet_hours`, `rate_cap`). The portal entry is always made.
- Shared recipients and alert webhooks (`alert_channels`, of a tenant or the platform): by
  category and minimum severity. Webhooks go through `QPBX.Integrations.request/3` (HTTPS
  only, public addresses), signed like event webhooks (`x-qpbx-signature`), retried 30 s
  doubling to 6 h apart for 24 hours, then dead; formats `generic` (`alert.raised |
  acknowledged | resolved`, the alert) and `alertmanager` (Alertmanager's webhook body; no
  acknowledgements).
- Email (`AlertEmail`): the recipient's language, an acknowledge link
  `/alerts/ack/<notification id>.<token>` (the token only in the email, its SHA-256 stored),
  "back to normal" when resolved. A permanent SMTP refusal is a hard bounce: `bounced`, not
  retried. Other failures are retried (10 attempts), then `dead`. Each attempt keeps the error
  in plain words (`AlertEmail.readable/1`) and the raw reason as `detail`.
- Every notification (one recipient, one channel, one event) is a row: status pending, sent,
  failed, dead, bounced, skipped; attempts logged.

**Sending email:** every email goes through `QPBX.Notify.Mail` (`deliver/1`, `sender/0`): the
SMTP server and sender saved on the platform settings page, else the installation's, read at
each send. `send_test_email/2` sends one now and returns `:ok` or `{:error, plain words}`;
`installation_email/0` gives the installation's values (the page's hints).

**Scoped API** (`QPBX.Notify.Inbox`): `list_alerts/3` (filters state, category, severity; a
tenant its own, the platform all), `get_alert/2`, `acknowledge_alert/3`, `resolve_alert/3`,
`acknowledge_by_token/1`, `send_test_notification/3`, `list_notifications/2`,
`unread_count/1`, `mark_read/2` (an id or `:all`), `my_preference/1`, `save_my_preference/2`,
`list_alert_channels/1`, `change_alert_channel/2`, `create_alert_channel/3` (`{:ok, channel,
secret}`; email: nil), `update_alert_channel/4`, `delete_alert_channel/3`,
`list_alert_deliveries/2`, `resend_notification/3`, `mandatory_categories/0`,
`set_mandatory_categories/3` (platform). Changes are audited.

**Alert sources** (`QPBX.Notify.Sources`, started by the application; off in tests):
`actions/1` maps each bus event to alerts to raise or resolve (pure, one test per source):
`EdgeBanned` (failed SIP logins against a tenant's domain: its `brute_force`; floods,
scanners, rate bans: one platform `sip_attack` alert, repeats grouped), `EdgeAlert` (office IP
spared), `FraudAlert` (`fraud_block` or `unusual_activity`), `LoginAlert` (`login_new_ip`,
`failed_2fa` to the person, platform admins included; failures on an account and blocked
addresses: `brute_force`), `HealthChanged` (FreeSWITCH, Kamailio, PostgreSQL: `service_down`;
disk, certificate, backups, job backlog; ok again resolves), `TrunkStatusChanged`
(`trunk_down`, resolved when up), `UsageThresholdReached` (severity info, warning from 90%,
critical at 100% with "emergency numbers still work"), `LimitReached`, `UsageSummary`,
`WebhookDeadLettered`, `CallEvent` missed and `VoicemailReceived` (to the user of the
extension), `ExtensionRegistration` (a device unregistered for `offline_minutes`, default 15,
raises `device_offline`; registered again resolves). Crash loops: `QPBX.Notify.CrashWatch`, a
logger handler, counts crash reports per kind of process; 3 within 5 minutes raise
`crash_loop`. Notices (`Catalogue.notice?/1`: logins, usage, missed calls, voicemail) are
recorded resolved. Audience `:account`: the person in the alert's data (users or platform
admins).

**Events emitted:** `AlertChanged` (raised, repeated, acknowledged, resolved),
`NotificationsChanged` (a person's portal list changed: the bell). **Consumed:** none yet
`EdgeBanned`, `EdgeAlert`, `FraudAlert`, `LoginAlert`, `HealthChanged`, `TrunkStatusChanged`,
`UsageThresholdReached`, `UsageSummary`, `LimitReached`, `WebhookDeadLettered`, `CallEvent`,
`VoicemailReceived`, `ExtensionRegistration` (the sources).

**Gotchas:** texts use their own Gettext backend `QPBX.Notify.Gettext`
(`priv/gettext_notify`). The mailer is `QPBX.Notify.Mailer`; no other area sends email
directly. Links use `config :qpbx, :portal_url`.
