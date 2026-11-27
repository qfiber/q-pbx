# Web (`QPBX.Web`)

**Purpose:** Phoenix endpoint (on 127.0.0.1:4000 behind nginx), LiveView portal (languages from
`config :qpbx, :locales`, RTL supported), health endpoint.
Later: REST API `/v1`, WebSocket event stream.

**Public API:** `QPBX.Web.Endpoint`, `QPBX.Web.Telemetry` (started by `QPBX.Application`);
`QPBX.Web.setup_url/1` (absolute setup-link URL built from endpoint config, usable without a
running endpoint).

**Health:** `QPBX.Web.Health` (exported; started by `QPBX.Application`): `current/0`, `run/1`,
`put/1`, `overall/1`. Routes `/health` and `/health/details`. Config `:qpbx, QPBX.Web.Health`
(`interval`, and per-check keyword lists `disk`, `certificate`, `freeswitch`, `kamailio`,
`oban_backlog`); a check with no config reports `not_configured` and does not count.

**Portal routes:** `/login`, `/platform/login`, `/2fa`, `/2fa/setup`, `/2fa/skip`,
`/setup/:token`, `/locale/:locale`, `/logout`; platform LiveViews under `/platform`
(tenants, new tenant, plans); tenant LiveViews under `/app`.

**Auth (`QPBX.Web.Auth`):** session key `account` = `{kind, id, logged_in_at}`, expiry
`:session_max_age` (seconds, default 12 h). `pending` holds an account between password and
TOTP for 5 minutes.

**Events emitted:** none. **Events consumed:** none yet.

**Real client IP:** `QPBX.Web.RealIP` (first plug in the endpoint) takes `X-Real-IP` only from
loopback peers, i.e. nginx. Use `conn.remote_ip` everywhere; never read forwarding headers.

**Languages:** `QPBX.Web.Locale` (`all/0`, `codes/0`, `options/0`, `dir/1`).

**Gotchas:**
- The web layer calls other areas only through their public API modules. It depends on
  `QPBX.Repo` only for the health check's `SELECT 1` and the Oban backlog count.
- Messages written in other areas' changesets must be listed in `QPBX.Web.ErrorMessages`
  to be translated. After `mix gettext.extract --merge`, fill in the `ar` `.po` files.
- Wrap LTR values (emails, domains, codes) in `dir="ltr"` so they render right in Arabic.
