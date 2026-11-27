# Notify (`QPBX.Notify`)

**Purpose:** phase 1 holds only the account setup-link email (English and Arabic). The full
notification service (alerts, preferences, push, webhooks) arrives in phase 3.

**Public API:** none yet.

**Events emitted:** none. **Events consumed:** none.

**Gotchas:** the mailer is `QPBX.Notify.Mailer`; no other area sends email directly.
