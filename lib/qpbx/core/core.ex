defmodule QPBX.Core do
  @moduledoc """
  Public API of the core area: tenants, plans, limits, users, roles and the audit log.
  See `lib/qpbx/core/CLAUDE.md`.
  """
  use Boundary, deps: [QPBX.Repo], exports: []
end
