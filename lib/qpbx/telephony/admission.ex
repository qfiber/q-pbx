defmodule QPBX.Telephony.Admission do
  @moduledoc """
  Call admission (toll-fraud protection), run by the call process:

    * `admit_call/3` when a call starts: the tenant's total and inbound concurrent caps, and
      the calling extension's own cap;
    * `admit_outbound/3` before every bridge to a carrier: emergency numbers pass (logged);
      otherwise the destination class must be allowed by the plan (premium, i.e. the
      high-cost list, only when the plan names it; an empty list allows every class but
      premium), no fraud block for international or premium, the outbound concurrent cap, the
      class's minutes per hour, day and month and the total outbound minutes per day and
      month; international and premium attempts feed the velocity rules (`Fraud`).

  A refusal is audited and announced (`LimitReached`). Concurrency is counted from live call
  processes (`QPBX.Telephony.Active`); a process leaving frees its slots.
  """
  require Logger
  alias QPBX.Core.Plan
  alias QPBX.Events
  alias QPBX.Events.LimitReached
  alias QPBX.Telephony.{Fraud, Usage}

  @active QPBX.Telephony.Active
  @actor {:system, "admission"}
  @default_classes ~w(local mobile international)

  ## Concurrency

  def join(key), do: Registry.register(@active, key, nil)
  def leave(key), do: Registry.unregister(@active, key)
  def count(key), do: length(Registry.lookup(@active, key))

  @doc "A call starts: `direction` is :inbound (from a carrier) or :internal (from a phone)."
  def admit_call(%{tenant: %{id: tid}, limits: limits}, direction, ext_id) do
    cond do
      over?(limits[:max_concurrent_calls_total], {:total, tid}) ->
        refuse(tid, :max_concurrent_calls_total, "NORMAL_CIRCUIT_CONGESTION")

      direction == :inbound and over?(limits[:max_concurrent_calls_inbound], {:in, tid}) ->
        refuse(tid, :max_concurrent_calls_inbound, "NORMAL_CIRCUIT_CONGESTION")

      ext_id && over?(limits[:max_concurrent_calls_per_extension], {:ext, ext_id}) ->
        refuse(tid, :max_concurrent_calls_per_extension, "USER_BUSY")

      true ->
        join({:total, tid})
        if direction == :inbound, do: join({:in, tid})
        if ext_id, do: join({:ext, ext_id})
        :ok
    end
  end

  @doc """
  Before a bridge to a carrier. `trunk_call`: `%{e164:, class:, emergency:}`. Returns
  `{:ok, seconds_left}` (nil: no minute cap applies) or `{:reject, cause}`.
  """
  def admit_outbound(_snapshot, %{emergency: true, e164: number}, from) do
    Logger.warning("emergency call to #{number} from #{inspect(from)}")
    QPBX.Core.audit(@actor, "call.emergency", nil, %{number: number, from: from})
    {:ok, nil}
  end

  def admit_outbound(%{tenant: t, limits: limits}, %{class: class} = trunk_call, _from) do
    tid = t.id
    risky? = class in ~w(international premium)

    with :ok <- class_allowed(tid, class, t.plan),
         :ok <- not_blocked(tid, risky?),
         :ok <- cap(tid, limits, :max_concurrent_calls_outbound, {:out, tid}),
         {:ok, left} <- minutes(tid, t.timezone, class, limits),
         :ok <- velocity(tid, t.timezone, risky?) do
      join({:out, tid})
      {:ok, left}
    else
      {:reject, _} = reject ->
        Logger.info("admission: #{tid} refused to #{trunk_call.e164} (#{class})")
        reject
    end
  end

  defp class_allowed(tid, class, plan) do
    allowed =
      case plan && plan.allowed_destination_classes do
        list when is_list(list) and list != [] -> list
        _ -> @default_classes
      end

    if class in allowed,
      do: :ok,
      else: refuse(tid, :destination_class, "OUTGOING_CALL_BARRED", class)
  end

  defp not_blocked(tid, true),
    do: if(Fraud.blocked?(tid), do: refuse(tid, :fraud_block, "OUTGOING_CALL_BARRED"), else: :ok)

  defp not_blocked(_tid, false), do: :ok

  defp cap(tid, limits, limit, key),
    do:
      if(over?(limits[limit], key),
        do: refuse(tid, limit, "NORMAL_CIRCUIT_CONGESTION"),
        else: :ok
      )

  # Minute caps of the class (hour, day, month) and the totals (day, month); the call may last
  # as long as the tightest one has left.
  defp minutes(tid, timezone, class, limits) do
    used = Usage.used(tid, timezone)
    mine = Map.get(used, class, %{hour: 0, day: 0, month: 0})
    total = fn period -> used |> Map.values() |> Enum.map(&(&1[period] || 0)) |> Enum.sum() end

    checks =
      for(
        {p, key} <- [{"hour", :hour}, {"day", :day}, {"month", :month}],
        do: {Plan.class_minutes_limit(class, p), mine[key] || 0}
      ) ++
        [{:outbound_minutes_per_day, total.(:day)}, {:outbound_minutes_per_month, total.(:month)}]

    left =
      for {limit, used_s} <- checks,
          cap = limits[limit],
          is_integer(cap),
          do: {limit, cap * 60 - used_s}

    case Enum.find(left, fn {_l, s} -> s <= 0 end) do
      {limit, _} -> refuse(tid, limit, "OUTGOING_CALL_BARRED")
      nil -> {:ok, left |> Enum.map(&elem(&1, 1)) |> Enum.min(fn -> nil end)}
    end
  end

  defp velocity(_tid, _tz, false), do: :ok

  defp velocity(tid, tz, true) do
    case Fraud.international_attempt(tid, tz) do
      :ok -> :ok
      {:blocked, rule} -> refuse(tid, :fraud_block, "OUTGOING_CALL_BARRED", rule)
    end
  end

  defp over?(nil, _key), do: false
  defp over?(cap, key), do: count(key) >= cap

  defp refuse(tid, limit, cause, detail \\ nil) do
    QPBX.Core.audit(@actor, "call.refused", nil, %{tenant_id: tid, limit: limit, detail: detail})

    Events.publish(%LimitReached{
      tenant_id: tid,
      limit: to_string(limit),
      detail: detail,
      at: DateTime.utc_now()
    })

    {:reject, cause}
  end
end
