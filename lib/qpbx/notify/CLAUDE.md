# Notify (`QPBX.Notify`)

**Purpose:** phase 1 holds only the account setup-link email (English and Arabic). The full
notification service (alerts, preferences, push, webhooks) arrives in phase 3.

**Public API:** `QPBX.Notify.deliver_setup_link(account, url)`: queues the setup-link email
(Oban queue `notify`, worker `QPBX.Notify.SetupLinkEmail`). `account` is any map with
`email`, `name`, `locale`.

**Events emitted:** none. **Events consumed:** none.

**Gotchas:** texts use their own Gettext backend `QPBX.Notify.Gettext` (`priv/gettext_notify`). The mailer is `QPBX.Notify.Mailer`; no other area sends email directly.
