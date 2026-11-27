# Web (`QPBX.Web`)

**Purpose:** Phoenix endpoint, LiveView portal (English and Arabic RTL), health endpoint.
Later: REST API `/v1`, WebSocket event stream.

**Public API:** `QPBX.Web.Endpoint`, `QPBX.Web.Telemetry` (started by `QPBX.Application`);
`QPBX.Web.setup_url/1` (absolute setup-link URL built from endpoint config, usable without a
running endpoint).

**Portal routes:** `/login`, `/platform/login`, `/2fa`, `/2fa/setup`, `/2fa/skip`,
`/setup/:token`, `/locale/:locale`, `/logout`; platform LiveViews under `/platform`
(tenants, new tenant, plans); tenant LiveViews under `/app`.

**Auth (`QPBX.Web.Auth`):** session key `account` = `{kind, id, logged_in_at}`, expiry
`:session_max_age` (seconds, default 12 h). `pending` holds an account between password and
TOTP for 5 minutes.

**Events emitted:** none. **Events consumed:** none yet.

**Gotchas:**
- The web layer calls other areas only through their public API modules.
- Messages written in other areas' changesets must be listed in `QPBX.Web.ErrorMessages`
  to be translated. After `mix gettext.extract --merge`, fill in the `ar` `.po` files.
- Wrap LTR values (emails, domains, codes) in `dir="ltr"` so they render right in Arabic.
