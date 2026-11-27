defmodule QPBX.Firewall do
  @moduledoc """
  Public API of the firewall area: allow and block lists applied to nftables through `qpbx-fwd`.
  See `lib/qpbx/firewall/CLAUDE.md`.
  """
  use Boundary, deps: [QPBX.Repo, QPBX.Core, QPBX.Events], exports: []
end
