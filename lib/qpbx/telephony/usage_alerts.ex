defmodule QPBX.Telephony.UsageAlerts do
  @moduledoc """
  Usage threshold alerts. After a carrier call's minutes are added, the tenant's outbound
  minutes this month are compared with `outbound_minutes_per_month`: each threshold (the
  tenant's, else its plan's: 50, 80, 90, 100 % by default) crossed by this call publishes
  `UsageThresholdReached` once, so each fires once per month. The projected run-out date is
  the period's daily average carried forward.

  `Summary` (Oban cron, the 1st of each month) publishes `UsageSummary` for every tenant that
  called last month.
  """
  alias QPBX.Events
  alias QPBX.Events.UsageThresholdReached
  alias QPBX.Telephony.Usage

  @limit :outbound_minutes_per_month

  @doc "Called after `seconds` were added for the tenant (snapshot from `QPBX.Telephony.Cache`)."
  def after_call(%{tenant: tenant, limits: limits}, seconds, now \\ DateTime.utc_now()) do
    with allowed when is_integer(allowed) and allowed > 0 <- limits[@limit] do
      month =
        tenant.id
        |> Usage.used(tenant.timezone, now)
        |> Map.values()
        |> Enum.map(& &1.month)
        |> Enum.sum()

      before = month - seconds
      thresholds = tenant.usage_thresholds || (tenant.plan && tenant.plan.usage_thresholds) || []

      for pct <- thresholds,
          before * 100 < pct * allowed * 60,
          month * 100 >= pct * allowed * 60 do
        Events.publish(%UsageThresholdReached{
          tenant_id: tenant.id,
          limit: to_string(@limit),
          percent: pct,
          used: minutes(month),
          allowed: allowed,
          period_end: period_end(now, tenant.timezone),
          run_out: run_out(month, allowed, now, tenant.timezone),
          at: now
        })
      end
    end

    :ok
  end

  # Minutes to a tenth (whole numbers stay whole).
  defp minutes(seconds) do
    m = Float.round(seconds / 60, 1)
    if m == Float.round(m), do: trunc(m), else: m
  end

  defp local_date(now, tz) do
    case DateTime.shift_zone(now, tz) do
      {:ok, l} -> DateTime.to_date(l)
      _ -> DateTime.to_date(now)
    end
  end

  defp period_end(now, tz), do: now |> local_date(tz) |> Date.end_of_month()

  # At the average per day so far, the day the allowance runs out (nil when it does not this month).
  defp run_out(seconds, allowed, now, tz) do
    today = local_date(now, tz)
    per_day = seconds / today.day

    if per_day > 0 do
      day = Float.ceil(allowed * 60 / per_day) |> trunc() |> max(1)
      date = Date.add(Date.beginning_of_month(today), day - 1)
      if Date.compare(date, Date.end_of_month(today)) == :gt, do: nil, else: date
    end
  end

  defmodule Summary do
    @moduledoc "Oban worker (cron, the 1st of each month): last month's usage per tenant (`UsageSummary`)."
    use Oban.Worker, queue: :calls, max_attempts: 3
    import Ecto.Query
    alias QPBX.Events.UsageSummary
    alias QPBX.Repo

    @impl Oban.Worker
    def perform(_job) do
      today = Date.utc_today()
      last = today |> Date.beginning_of_month() |> Date.add(-1)
      from = Date.beginning_of_month(last)

      rows =
        Repo.all(
          from u in "usage_daily",
            where: u.day >= ^from and u.day <= ^last,
            group_by: [u.tenant_id, u.direction],
            select: {u.tenant_id, u.direction, sum(u.calls), sum(u.answered), sum(u.seconds)}
        )

      for {tid, list} <- Enum.group_by(rows, &elem(&1, 0)) do
        totals =
          Map.new(list, fn {_, dir, calls, answered, secs} ->
            {dir, %{calls: calls, answered: answered, minutes: div(secs || 0, 60)}}
          end)

        QPBX.Events.publish(%UsageSummary{
          tenant_id: Ecto.UUID.load!(tid),
          month: Calendar.strftime(last, "%Y-%m"),
          totals: totals,
          at: DateTime.utc_now()
        })
      end

      :ok
    end
  end
end
