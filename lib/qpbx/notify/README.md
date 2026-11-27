# Notify (`QPBX.Notify`)

**Purpose:** the account setup-link email and the new-voicemail email (English and Arabic).
The full notification service (alerts, preferences, push, webhooks) arrives in phase 3.

**Public API:** `QPBX.Notify.deliver_setup_link(account, url)`: queues the setup-link email
(Oban queue `notify`, worker `QPBX.Notify.SetupLinkEmail`). `account` is any map with
`email`, `name`, `locale`. `QPBX.Notify.deliver_voicemail(vm)`: queues the voicemail email
(worker `QPBX.Notify.VoicemailEmail`; `vm`: email, locale, extension, caller, caller_name,
duration, at, format, file_key). The job holds the storage key, never the audio; the audio is
decrypted (`QPBX.Storage.get/1`) while the email is built and attached when a key is given. A
message deleted before the email goes out discards the job.

**Events emitted:** none. **Events consumed:** none.

**Gotchas:** texts use their own Gettext backend `QPBX.Notify.Gettext` (`priv/gettext_notify`). The mailer is `QPBX.Notify.Mailer`; no other area sends email directly.
