# Web (`QPBX.Web`)

**Purpose:** Phoenix endpoint (on 127.0.0.1:4000 behind nginx), LiveView portal (languages from
`config :qpbx, :locales`, RTL supported), health endpoint.
Later: REST API `/v1`, WebSocket event stream.

**Public API:** `QPBX.Web.Endpoint`, `QPBX.Web.Telemetry` (started by `QPBX.Application`);
`QPBX.Web.setup_url/1` (absolute setup-link URL built from endpoint config, usable without a
running endpoint).

**Health:** `QPBX.Web.Health` (exported; started by `QPBX.Application`): `current/0`, `run/1`,
`put/1`, `overall/1`. Routes `/health` and `/health/details`. Config `:qpbx, QPBX.Web.Health`
(`interval`, and per-check keyword lists `disk`, `certificate` (`path`, and `tenants_dir`: every
tenant certificate is checked too, and one near expiry, i.e. a failing renewal, is named),
`freeswitch`, `kamailio`,
`oban_backlog`, `backups`: `status_dir` with the backup jobs' `db.json` and `files.json`, error
when a run failed or none ran, warning when the last success is over 26 h old); a check with no
config reports `not_configured` and does not count.

**Portal routes:** `/login`, `/platform/login`, `/2fa`, `/2fa/setup`, `/2fa/skip`,
`/setup/:token`, `/locale/:locale`, `/logout`; platform LiveViews under `/platform`
(tenants, new tenant, `/platform/tenants/:id` (edit, limit overrides, users with new setup
link and sign out everywhere, another tenant admin), `/platform/admins`, `/platform/audit`,
plans and `/platform/plans/:id` to edit one, firewall, trunks, numbers, numbering, protection, fraud); tenant LiveViews under
`/app`. The tenant configuration pages (`/app/extensions`, `/app/extensions/:id`,
`/app/numbers`, `/app/routes`, `/app/office-ips`, `/app/number-format`,
`/app/extensions/:id/voicemail` (mailbox and greetings), `/app/voicemail` (messages, played
in the browser; playing marks heard), `/app/calls` (call history with filters in the URL,
daily totals), `/app/users` (invite, extension, role, new setup link, sign out everywhere,
remove), `/app/audit` (the tenant's own audit log)) are in the
`:tenant_admin` live session: tenant users are sent back to `/app`. `QPBX.Web.NumberInput`
turns numbers typed the local way into E.164 with the scope's number rule before Core sees
them. A device's SIP password is shown once, after creation or reset.

**My extension:** `/app/me` (`:tenant_user` live session, every tenant user): the user's own
extension's voicemail, recent calls, forwarding and DND, and devices (read only).

**Voicemail audio:** `GET /app/voicemail/:id/audio` (`VoicemailController`): the decrypted
message for a signed-in tenant admin of its tenant, or for the tenant user whose own extension
it belongs to (404 otherwise), `cache-control: private,
no-store`. Deleting an extension deletes its mailbox (files included) first.

**Call records export:** `GET /app/calls/export` (`CallsController`, tenant admins; the same
filters as the Calls page): CSV streamed in chunks; a cell starting with `=`, `+`, `-` or `@`
that is not a plain number gets a leading `'` (no spreadsheet formulas from caller names).

**FreeSWITCH:** `POST /internal/freeswitch/dialplan` (`FreeswitchController`): loopback only
(a request through nginx carries the client's address) and HTTP basic auth with FreeSWITCH's
password; answers `QPBX.Telephony.dialplan_xml/1`. nginx returns 404 for `/internal/`.

**Logo:** `priv/static/images/logo.svg` (source, brand teal `#174355`), `logo-dark.svg` (for
dark backgrounds, used by the README), `logo-mark.svg` (the hexagon alone: the SVG favicon;
`favicon.ico` is made from it). `QPBX.Web.Logo.logo/1` draws it inline from `logo.svg` (read
at compile time) in the theme's colour (`.qpbx-logo` in `app.css`).

**Auth (`QPBX.Web.Auth`):** the cookie holds `session_token` (checked in the database on every
request, LiveView event and every 30 s) and `live_socket_id` (`sessions:<id>`);
`QPBX.Web.SessionReaper` broadcasts "disconnect" there when Core announces revoked sessions.
`pending` holds an account between password and TOTP for 5 minutes. Pages pass
`idle_timeout={@idle_timeout}` to `Layouts.app` for the idle warning (JS hook `IdleWarning`).

**Events emitted:** none. **Events consumed:** `SessionsRevoked`.

**Real client IP:** `QPBX.Web.RealIP` (first plug in the endpoint) takes `X-Real-IP` only from
loopback peers, i.e. nginx. Use `conn.remote_ip` everywhere; never read forwarding headers.

**Login protection:** `QPBX.Web.LoginProtection` (plug on login, 2FA and setup controllers:
429 for blocked IPs, `failed/2`, `succeeded/1`, `human?/2`, `captcha_assigns/1`; allowlisted
IPs exempt). `QPBX.Web.Captcha` (`provider/0`, `verify/2`, `widget/1`) with `Pow`, `Turnstile`,
`FriendlyCaptcha`, `CaptchaEU`; `Captcha.PowStore` remembers used challenges (per node).

**Content-Security-Policy:** `QPBX.Web.CSP` (browser pipeline). No inline scripts: put JS in
`assets/js` or `priv/static`. A new outside script host goes into its provider entry.

**Languages:** `QPBX.Web.Locale` (`all/0`, `codes/0`, `options/0`, `dir/1`).

**Gotchas:**
- The web layer calls other areas only through their public API modules. It depends on
  `QPBX.Repo` only for the health check's `SELECT 1` and the Oban backlog count.
- Messages written in other areas' changesets must be listed in `QPBX.Web.ErrorMessages`
  to be translated. After `mix gettext.extract --merge`, fill in the `ar` `.po` files.
- Wrap LTR values (emails, domains, codes) in `dir="ltr"` so they render right in Arabic.
