# Web (`QPBX.Web`)

**Purpose:** Phoenix endpoint (on 127.0.0.1:4000 behind nginx), LiveView portal (languages from
`config :qpbx, :locales`, RTL supported), health endpoint, REST API `/v1`.
Later: WebSocket event stream.

**Public API:** `QPBX.Web.Endpoint`, `QPBX.Web.Telemetry`, `QPBX.Web.Api.RateLimit` (started by `QPBX.Application`);
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

**REST API (`/v1`, `lib/qpbx/web/api/`):**
- Pipeline: `QPBX.Web.Api.Auth` (key from `Authorization: Bearer qpbx_...`, checked in the
  database on every request; then `QPBX.Web.Api.RateLimit`: per key per minute, the plan's
  `api_rate_limit_per_minute` with tenant overrides, platform keys `:platform_api_rate_limit`
  (default 600); headers `x-ratelimit-limit`, `x-ratelimit-remaining`, `retry-after` on 429).
  Assigns `api_key` and `current_scope` (`Core.scope_for(key)`); the key is the audit actor.
- Controllers `use QPBX.Web, :api_controller` and describe every action in `operation/1`
  (`summary`, `tag`, `scope`, `audience` `:tenant | :platform | :any`, `params`, `body`,
  `response`, `status`). `QPBX.Web.Api.Authorize` enforces scope and audience from it (403
  `missing_scope` / `wrong_key_kind`) and `QPBX.Web.Api.Spec` builds the OpenAPI 3.1 document
  from the router and the same descriptions: a `/v1` route without one fails the tests.
- One error format (`QPBX.Web.Api.Error`): `{"error": {"code", "message", "details"}}`; action
  `{:error, _}` through `QPBX.Web.Api.Fallback`, raised errors (not found, malformed id)
  through `QPBX.Web.ErrorJSON`.
- Lists: `QPBX.Web.Api.Page` (`limit` 1 to 200, `cursor`, `next_cursor`; ordered by id).
- POST with `Idempotency-Key` (`QPBX.Web.Api.Idempotency`): the first response is kept 24
  hours and replayed (`idempotent-replayed: true`); another body with the same key is 422
  `idempotency_key_reused`; 409 while the first runs; 5xx responses are not kept.
- Records: `QPBX.Web.Api.Schemas.render/1` and `of/3` / `input/4` (OpenAPI) derive both the
  JSON and its schema from the Ecto schema; redacted fields and a fixed list of secret names
  (password hashes, TOTP secrets, PIN hashes, file keys) are never rendered; loaded has-many
  associations nest (`extras/1` adds a few derived values: a device's SIP username, a user's
  role, a route's trunk ids).
- Controllers use `QPBX.Web.Api.Helpers` (`op/5` one-line descriptions, `data/3`, `paged/3`,
  `reply/3`, `query/3`). Each calls the same public functions the portal page does.
- Routes (`router.ex`, one `/v1` scope behind the key pipeline): platform `tenants` (with
  users, setup links, sign-out), `plans`, `trunks`, `numbers` (add, assign, remove),
  `number-classes`, `emergency-routes`, `firewall`, `protection` (+ `bans`), `fraud`
  (+ `blocks`), `platform-admins`; either kind: `me`, `api-keys` (admin), `audit`,
  `numbers` (read), `number-format`; tenant `extensions` (+ `devices`, `mailbox`,
  `greetings`), `voicemails` (+ `audio-link`), `users` (admin), `routes`, `office-ips`,
  `calls` (+ `export` CSV), `usage/daily`. Numbers are E.164 in the API (no local formats).
  A device's SIP password and a new key's token are in the creating response only; setup
  links are only emailed, never returned.
- Voicemail audio: `POST /v1/voicemails/:id/audio-link` gives a `Phoenix.Token` link valid 5
  minutes, `GET /v1/voicemail-audio/:token` (`VoicemailAudioController`, no key) serves it.
- Public: `GET /v1/openapi.json` and `GET /v1/docs` (the explorer: this app's own script
  `assets/js/api_explorer.js`, portal CSP, DOM built without `innerHTML`; uploads, whose body
  is not JSON, are not sent from it). `QPBX.Web.Api.Spec.unkeyed/0` lists the `/v1`
  controllers outside the key pipeline.
- Parity: `test/qpbx/web/api/parity_test.exs` maps every portal page event to its API route;
  a new portal action without one fails it.

**API keys page:** `QPBX.Web.Account.ApiKeysLive` at `/app/api-keys` (tenant admins) and
`/platform/api-keys` (platform admins): create (name, scopes, expiry 30/90/365 days or never;
the key shown once), list by prefix with last use, revoke.

**My extension:** `/app/me` (`:tenant_user` live session, every tenant user): the user's own
extension's voicemail, recent calls, forwarding and DND, and devices (read only).

**Voicemail audio:** `GET /app/voicemail/:id/audio` (`VoicemailController`): the decrypted
message for a signed-in tenant admin of its tenant, or for the tenant user whose own extension
it belongs to (404 otherwise), `cache-control: private,
no-store`. Deleting an extension deletes its mailbox (files included) first.

**Call records export:** `GET /app/calls/export` (`CallsController`, tenant admins; the same
filters as the Calls page; `send_csv/4` is shared with the API's export): CSV streamed in chunks; a cell starting with `=`, `+`, `-` or `@`
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

**Events emitted:** none (an API key's changes are audited by Core). **Events consumed:** `SessionsRevoked`.

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
