defmodule QPBX.Events.UsageThresholdReached do
  @moduledoc """
  A tenant's use of a limit crossed a threshold of its plan (once per period): `limit` (e.g.
  outbound_minutes_per_month), `percent`, `used` and `allowed` (minutes), `period_end` (date),
  `run_out` (projected date at the period's daily average, nil when not reached this period).
  Feeds the `usage.threshold_reached` webhook and the usage alert. Version 1.
  """
  @enforce_keys [:tenant_id, :limit, :percent, :at]
  defstruct version: 1,
            id: nil,
            tenant_id: nil,
            limit: nil,
            percent: nil,
            used: nil,
            allowed: nil,
            period_end: nil,
            run_out: nil,
            at: nil

  def topic, do: "usage"
end
