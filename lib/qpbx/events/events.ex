defmodule QPBX.Events do
  @moduledoc """
  Public API of the event bus: typed, versioned event structs on Phoenix.PubSub.
  See `lib/qpbx/events/CLAUDE.md`.
  """
  use Boundary, deps: [], exports: []
end
