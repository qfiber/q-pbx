# Web (`QPBX.Web`)

**Purpose:** Phoenix endpoint, LiveView portal (English and Arabic RTL), health endpoint.
Later: REST API `/v1`, WebSocket event stream.

**Public API:** `QPBX.Web.Endpoint`, `QPBX.Web.Telemetry` (started by `QPBX.Application`).

**Events emitted:** none. **Events consumed:** none yet.

**Gotchas:** the web layer calls other areas only through their public API modules.
