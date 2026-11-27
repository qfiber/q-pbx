defmodule QPBX.Telephony.Call do
  @moduledoc """
  One call: started when FreeSWITCH parks it, asks `Router` what to do, and walks the action
  tree over the event socket (bridge, then the busy / no answer / failed branch). Ends when
  the channel hangs up. A crash here ends this call only.
  """
  use GenServer, restart: :temporary
  require Logger
  alias QPBX.Telephony.{Cache, Calls, Router}
  alias QPBX.Telephony.ESL.Connection

  def start_link(event),
    do: GenServer.start_link(__MODULE__, event, name: Calls.via(event["Unique-ID"]))

  @impl true
  def init(event) do
    call = %{
      uuid: event["Unique-ID"],
      source: source(event["variable_sip_h_X-QPBX-Source"]),
      tenant_id: event["variable_sip_h_X-QPBX-Tenant"],
      auth_user: event["variable_sip_h_X-QPBX-Auth-User"],
      trunk_id: event["variable_sip_h_X-QPBX-Trunk"],
      destination: event["Caller-Destination-Number"] || "",
      caller: event["Caller-Caller-ID-Number"]
    }

    {:ok, %{call: call, action: nil, pending: nil}, {:continue, :route}}
  end

  @impl true
  def handle_continue(:route, %{call: call} = s) do
    action = decide(call)
    Logger.info("call #{call.uuid}: #{call.source} #{call.caller} -> #{call.destination}")
    {:noreply, run(action, s)}
  end

  @impl true
  def handle_info({:event, "CHANNEL_EXECUTE_COMPLETE", e}, %{pending: id, action: action} = s)
      when id != nil do
    if e["Application-UUID"] == id do
      outcome = outcome(e)
      {:noreply, after_dial(outcome, action, %{s | pending: nil})}
    else
      {:noreply, s}
    end
  end

  # Answered and connected: the extension rung is on a call (call waiting off makes it busy).
  def handle_info({:event, "CHANNEL_BRIDGE", _e}, %{action: %{ext_id: ext_id}} = s)
      when is_binary(ext_id) do
    Calls.mark_in_use(ext_id)
    {:noreply, s}
  end

  def handle_info({:event, "CHANNEL_HANGUP_COMPLETE", _e}, s), do: {:stop, :normal, s}
  def handle_info({:event, _name, _e}, s), do: {:noreply, s}

  ## Deciding

  defp decide(call) do
    base = %{platform: Cache.platform(), dids: Cache.dids(), in_use: Calls.in_use()}

    case Router.plan(call, Map.put(base, :tenant, Cache.tenant(call.tenant_id))) do
      {:tenant_needed, tid, did, caller} ->
        case Cache.tenant(tid) do
          nil -> %{op: :reject, cause: "UNALLOCATED_NUMBER"}
          tenant -> Router.plan_did(did, caller, Map.put(base, :tenant, tenant))
        end

      action ->
        action
    end
  rescue
    e ->
      Logger.error("call #{call.uuid}: routing failed: #{Exception.message(e)}")
      %{op: :reject, cause: "NORMAL_TEMPORARY_FAILURE"}
  end

  ## Doing

  defp run(%{op: :reject, cause: cause}, s) do
    Connection.hangup(s.call.uuid, cause)
    %{s | action: nil}
  end

  defp run(%{op: :dial} = action, s) do
    uuid = s.call.uuid
    id = Ecto.UUID.generate()
    Connection.execute(uuid, "set", "call_timeout=#{action.timeout}", Ecto.UUID.generate())

    case Connection.execute(uuid, "bridge", action.dial, id) do
      {:ok, _} ->
        %{s | action: action, pending: id}

      {:error, reason} ->
        Logger.error("call #{uuid}: bridge not started: #{inspect(reason)}")
        run(action.failed, s)
    end
  end

  defp after_dial(:answered, _action, s) do
    # The call happened; when the bridge ends, so does the call.
    Connection.hangup(s.call.uuid, "NORMAL_CLEARING")
    s
  end

  defp after_dial(:cancelled, _action, s), do: s
  defp after_dial(outcome, action, s), do: run(Map.fetch!(action, outcome), s)

  @doc false
  # What a finished bridge means for the next step.
  def outcome(e) do
    case e["variable_originate_disposition"] || e["variable_DIALSTATUS"] do
      d when d in ["SUCCESS", "ANSWER"] ->
        :answered

      d when d in ["USER_BUSY", "CALL_REJECTED", "BUSY"] ->
        :busy

      d
      when d in [
             "NO_ANSWER",
             "NO_USER_RESPONSE",
             "ALLOTTED_TIMEOUT",
             "USER_NOT_REGISTERED",
             "SUBSCRIBER_ABSENT",
             "NOANSWER"
           ] ->
        :no_answer

      d when d in ["ORIGINATOR_CANCEL", "CANCEL"] ->
        :cancelled

      _ ->
        :failed
    end
  end

  defp source("device"), do: :device
  defp source("trunk"), do: :trunk
  defp source(_), do: :unknown
end
