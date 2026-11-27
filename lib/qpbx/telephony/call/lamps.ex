defmodule QPBX.Telephony.Call.Lamps do
  @moduledoc """
  Busy lamps of one call (`QPBX.Edge` publishes `CallState` to Kamailio's presence server):
  the extensions this call shows as early, confirmed or terminated, kept in the call state's
  `lamps` map so each change is published once.
  """

  def lamp(s, ext, domain, peer, direction, state) do
    key = {ext, domain}

    if s.lamps[key] == {direction, state} do
      s
    else
      QPBX.Events.publish(%QPBX.Events.CallState{
        tenant_id: s.call.tenant_id,
        domain: domain,
        extension: ext,
        peer: peer,
        call_id: "#{s.call.uuid}-#{ext}",
        state: state,
        direction: direction,
        at: DateTime.utc_now()
      })

      lamps =
        if state == "terminated",
          do: Map.delete(s.lamps, key),
          else: Map.put(s.lamps, key, {direction, state})

      %{s | lamps: lamps}
    end
  end

  def caller_lamp(%{caller_ext: %{number: n, domain: d}} = s, state),
    do: lamp(s, n, d, s.call.destination, "initiator", state)

  def caller_lamp(s, _state), do: s

  def lamps_off(s) do
    Enum.reduce(s.lamps, s, fn {{ext, domain}, {direction, _}}, acc ->
      lamp(acc, ext, domain, nil, direction, "terminated")
    end)
  end
end
