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
  email carries warning and critical alerts only; info stays in the portal. Categories platform
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
  retried.
- Every notification (one recipient, one channel, one event) is a row: status pending, sent,
  failed, dead, bounced, skipped; attempts logged.

**Scoped API** (`QPBX.Notify.Inbox`): `list_alerts/3` (filters state, category, severity; a
tenant its own, the platform all), `get_alert/2`, `acknowledge_alert/3`, `resolve_alert/3`,
`acknowledge_by_token/1`, `send_test_notification/3`, `list_notifications/2`,
`unread_count/1`, `mark_read/2` (an id or `:all`), `my_preference/1`, `save_my_preference/2`,
`list_alert_channels/1`, `change_alert_channel/2`, `create_alert_channel/3` (`{:ok, channel,
secret}`; email: nil), `update_alert_channel/4`, `delete_alert_channel/3`,
`list_alert_deliveries/2`, `resend_notification/3`, `mandatory_categories/0`,
`set_mandatory_categories/3` (platform). Changes are audited.

**Events emitted:** `AlertChanged` (raised, repeated, acknowledged, resolved),
`NotificationsChanged` (a person's portal list changed: the bell). **Consumed:** none yet
(the sources in 3-9 call `raise_alert/1`).

**Gotchas:** texts use their own Gettext backend `QPBX.Notify.Gettext`
(`priv/gettext_notify`). The mailer is `QPBX.Notify.Mailer`; no other area sends email
directly. Links use `config :qpbx, :portal_url`.
