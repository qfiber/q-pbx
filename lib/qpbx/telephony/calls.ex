defmodule QPBX.Telephony.Calls do
  @moduledoc """
  Routes event socket events to call processes: a call parked by our dialplan
  (`qpbx_call=true`) gets a process (`QPBX.Telephony.Call`, one per call, under a dynamic
  supervisor); later events for its channel go to that process.
  """
  alias QPBX.Telephony.Call

  @registry QPBX.Telephony.Registry
  @supervisor QPBX.Telephony.CallSupervisor

  def dispatch(%{"Unique-ID" => uuid, "Event-Name" => name} = event) do
    case Registry.lookup(@registry, uuid) do
      [{pid, _}] ->
        send(pid, {:event, name, event})

      [] when name == "CHANNEL_PARK" ->
        if event["variable_qpbx_call"] == "true",
          do: DynamicSupervisor.start_child(@supervisor, {Call, event})

      [] ->
        :ok
    end

    :ok
  end

  def dispatch(_event), do: :ok

  def via(uuid), do: {:via, Registry, {@registry, uuid}}

  @doc "Extension ids currently on an answered call (call waiting)."
  def in_use do
    Registry.select(QPBX.Telephony.InUse, [{{:"$1", :_, :_}, [], [:"$1"]}]) |> MapSet.new()
  end

  def mark_in_use(ext_id), do: Registry.register(QPBX.Telephony.InUse, ext_id, nil)

  def count, do: DynamicSupervisor.count_children(@supervisor).active
end
