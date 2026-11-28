defmodule QPBX.Events.HealthChanged do
  @moduledoc """
  A health check's component settled into a new status (`ok`, `warning`, `error`) for two runs
  in a row: `component` (postgres, freeswitch, kamailio, disk, trunk_registrations,
  oban_backlog, certificate, backups), `detail`. Version 1.
  """
  @enforce_keys [:component, :status, :at]
  defstruct version: 1, component: nil, status: nil, previous: nil, detail: nil, at: nil

  def topic, do: "health"
end
