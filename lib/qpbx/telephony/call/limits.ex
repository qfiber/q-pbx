defmodule QPBX.Telephony.Call.Limits do
  @moduledoc """
  Call admission as the call process applies it: the concurrent caps when the call starts,
  each carrier destination admitted once (failover reuses it), the minute cap as a
  `sched_hangup` on the carrier leg, and talk time recorded when the carrier call ends.
  Functions take and return the call state.
  """
  require Logger
  alias QPBX.Telephony.{Admission, Cache, Usage}

  def safe_tenant(tid) do
    Cache.tenant(tid)
  rescue
    _ -> nil
  end

  def admit_call(%{tenant_id: nil}, _direction, _ext_id), do: :ok

  def admit_call(s, direction, ext_id) do
    case safe_tenant(s.tenant_id) do
      nil -> :ok
      snapshot -> Admission.admit_call(snapshot, direction, ext_id)
    end
  end

  def admit_outbound(%{e164: number} = meta, s) do
    case Map.fetch(s.admitted, number) do
      # The next carrier for the same number (failover): admitted already; the outbound slot
      # the failed attempt gave back is taken again.
      {:ok, left} ->
        unless meta.emergency, do: Admission.join({:out, s.tenant_id})
        {:ok, left, s}

      :error ->
        snapshot = safe_tenant(s.tenant_id)
        from = s.caller_ext && s.caller_ext.number

        case snapshot && Admission.admit_outbound(snapshot, meta, from) do
          {:ok, left} -> {:ok, left, %{s | admitted: Map.put(s.admitted, number, left)}}
          {:reject, cause} -> {:reject, cause, s}
          nil -> {:reject, "NORMAL_TEMPORARY_FAILURE", s}
        end
    end
  end

  # The tightest minute cap left: the carrier leg hangs up when it runs out.
  def limit_duration(action, nil), do: action

  def limit_duration(%{dial: dial} = action, left) do
    var = "execute_on_answer='sched_hangup +#{max(left, 1)} ALLOTTED_TIMEOUT'"

    dial =
      case dial do
        "{" <> rest -> "{" <> var <> "," <> rest
        _ -> "{" <> var <> "}" <> dial
      end

    %{action | dial: dial}
  end

  # A carrier call ended (or this call did): its talk time goes to the usage, its slot is freed.
  def stop_talking(%{talking: {meta, since}} = s) do
    seconds = DateTime.diff(DateTime.utc_now(), since)
    Usage.add(s.tenant_id, meta.class, seconds, since)
    Admission.leave({:out, s.tenant_id})

    snapshot = seconds > 0 && safe_tenant(s.tenant_id)
    if snapshot, do: QPBX.Telephony.UsageAlerts.after_call(snapshot, seconds)

    %{s | talking: nil}
  rescue
    e ->
      Logger.error("call #{s.call.uuid}: usage not recorded: #{Exception.message(e)}")
      %{s | talking: nil}
  end

  def stop_talking(%{action: %{trunk_call: %{}}} = s) do
    Admission.leave({:out, s.tenant_id})
    s
  end

  def stop_talking(s), do: s
end
