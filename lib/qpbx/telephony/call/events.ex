defmodule QPBX.Telephony.Call.Events do
  @moduledoc false
  # The call.* events of one call (QPBX.Events.CallEvent), from the call process's state.
  # Published synchronously, so their order is the call's order. A call no tenant claimed
  # publishes nothing.
  alias QPBX.Events
  alias QPBX.Events.CallEvent

  def started(s, action) do
    direction =
      cond do
        s.call.source == :trunk -> "inbound"
        is_map(action) and is_map(action[:trunk_call]) -> "outbound"
        true -> "internal"
      end

    s = %{s | direction: direction}
    publish(s, "started", %{to: s.call.destination})
    s
  end

  @doc "The dial just started rings (once per dial); an extension rung is remembered for `missed`."
  def ringing(%{ringing: false, action: %{op: :dial} = a} = s) do
    publish(s, "ringing", %{target: target(a)})
    %{s | ringing: true}
  end

  def ringing(s), do: s

  def dialing(%{action: %{ext_id: id}} = s) when is_binary(id),
    do: %{s | ringing: false, rung: Enum.uniq(s.rung ++ [id])}

  def dialing(s), do: %{s | ringing: false}

  def answered(s) do
    publish(s, "answered", %{target: target(s.action)})
    %{s | answered: true}
  end

  def transferred(s, to) do
    publish(s, "transferred", %{to: to, target: target(s.action)})
    s
  end

  def ended(s, e) do
    disposition = disposition(s, e["Hangup-Cause"])

    publish(s, "ended", %{
      disposition: disposition,
      cause: e["Hangup-Cause"],
      duration: int(e["variable_duration"]),
      billsec: int(e["variable_billsec"])
    })

    if not s.answered and s.rung != [] and s.direction != "outbound",
      do: publish(s, "missed", %{extension_ids: s.rung, disposition: disposition})

    s
  end

  defp disposition(s, cause) do
    cond do
      s.answered -> "answered"
      s.vm -> "voicemail"
      cause in ["USER_BUSY", "CALL_REJECTED"] -> "busy"
      s.rung != [] or s.ringing -> "no_answer"
      true -> "failed"
    end
  end

  defp target(%{ext_id: id, ext_number: n}) when is_binary(id),
    do: %{type: "extension", extension_id: id, number: n}

  defp target(%{trunk_call: %{e164: n}}), do: %{type: "external", number: n}
  defp target(_), do: %{type: "other"}

  defp publish(%{tenant_id: nil}, _type, _fields), do: :ok

  defp publish(s, type, fields) do
    base = %CallEvent{
      type: type,
      tenant_id: s.tenant_id,
      call_id: s.call.uuid,
      direction: s.direction,
      from: s.call.caller,
      from_name: s.call.caller_name,
      to: s.call.destination,
      extension_id: s.caller_ext && s.caller_ext.id,
      at: DateTime.utc_now()
    }

    Events.publish(struct!(base, fields))
  end

  defp int(nil), do: nil

  defp int(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end
end
