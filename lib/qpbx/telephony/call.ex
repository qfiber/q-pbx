defmodule QPBX.Telephony.Call do
  @moduledoc """
  One call: started when FreeSWITCH parks it, asks `Router` what to do, and walks the action
  tree over the event socket (bridge, then the busy / no answer / failed branch). Follows a
  transfer (FreeSWITCH re-parks the channel with a new destination after a REFER) and a 302
  redirect (up to 3 times) by routing the new destination with the same caller. Ends when
  the channel hangs up. A crash here ends this call only.
  """
  use GenServer, restart: :temporary

  @max_redirects 3
  require Logger
  alias QPBX.Telephony.{Cache, Calls, Cdrs, Router, Voicemail, VoicemailFlow}
  alias QPBX.Telephony.ESL.Connection
  import QPBX.Telephony.Call.Lamps, only: [lamp: 6, caller_lamp: 2, lamps_off: 1]

  import QPBX.Telephony.Call.Limits,
    only: [admit_call: 3, admit_outbound: 2, limit_duration: 2, stop_talking: 1, safe_tenant: 1]

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
      caller: event["Caller-Caller-ID-Number"],
      caller_name: event["Caller-Caller-ID-Name"]
    }

    state = %{
      call: call,
      action: nil,
      pending: nil,
      caller_ext: nil,
      lamps: %{},
      # The tenant the call was routed in (for a carrier call, the number's).
      tenant_id: call.tenant_id,
      transfer_history: event["variable_transfer_history"],
      awaiting_transfer: false,
      redirects: 0,
      # Call admission: destinations already admitted (number => seconds left), and the
      # carrier call being timed for usage ({meta, bridged_at}).
      admitted: %{},
      talking: nil,
      # Voicemail (leaving a message or the mailbox menu): QPBX.Telephony.VoicemailFlow state.
      vm: nil
    }

    {:ok, state, {:continue, :route}}
  end

  @impl true
  def handle_continue(:route, %{call: call} = s) do
    {action, tenant_id} = decide(call)
    s = %{s | tenant_id: tenant_id}
    Logger.info("call #{call.uuid}: #{call.source} #{call.caller} -> #{call.destination}")

    caller_ext =
      if call.source == :device,
        do: Router.caller_extension(safe_tenant(call.tenant_id), call.auth_user)

    # Lamps name a phone's caller by its extension, not its device login.
    call = if caller_ext, do: %{call | caller: caller_ext.number}, else: call
    s = %{s | caller_ext: caller_ext, call: call}

    for {app, arg} <- Cdrs.tags(call, tenant_id, call.caller),
        do: Connection.execute(call.uuid, app, arg, Ecto.UUID.generate())

    s =
      if caller_ext,
        do: lamp(s, caller_ext.number, caller_ext.domain, call.destination, "initiator", "early"),
        else: s

    # Concurrent call caps of the tenant (and of the calling extension) before anything rings.
    direction = if call.source == :trunk, do: :inbound, else: :internal

    case admit_call(s, direction, caller_ext && caller_ext.id) do
      :ok -> {:noreply, run(action, s)}
      {:reject, cause} -> {:noreply, run(%{op: :reject, cause: cause}, s)}
    end
  end

  @impl true
  def handle_info({:event, "CHANNEL_EXECUTE_COMPLETE", e}, %{vm: vm, pending: id} = s)
      when vm != nil and id != nil do
    if e["Application-UUID"] == id do
      {apps, vm} = VoicemailFlow.next(e, vm)
      {:noreply, flow(apps, %{s | vm: vm, pending: nil})}
    else
      {:noreply, s}
    end
  end

  def handle_info({:event, "CHANNEL_EXECUTE_COMPLETE", e}, %{pending: id, action: action} = s)
      when id != nil do
    cond do
      e["Application-UUID"] != id ->
        {:noreply, s}

      # A REFER moved this channel: FreeSWITCH parks it again with the new destination.
      transferred?(e["variable_transfer_history"], s.transfer_history) ->
        s = s |> leave_current() |> Map.merge(%{pending: nil, awaiting_transfer: true})
        {:noreply, %{s | transfer_history: e["variable_transfer_history"]}}

      # The far end answered 302: route the new destination for the same caller.
      (target = redirect_target(e)) && outcome(e) != :answered && s.redirects < @max_redirects ->
        Logger.info("call #{s.call.uuid}: redirected to #{target}")
        s = s |> leave_current() |> Map.merge(%{pending: nil, redirects: s.redirects + 1})
        {:noreply, run(reroute(s, target), s)}

      true ->
        {:noreply, after_dial(outcome(e), action, stop_talking(%{s | pending: nil}))}
    end
  end

  # Parked again after a transfer (or with a new destination): route it.
  def handle_info({:event, "CHANNEL_PARK", e}, s) do
    target = e["Caller-Destination-Number"]

    if s.awaiting_transfer or (target && target != s.call.destination) do
      Logger.info("call #{s.call.uuid}: transferred to #{target}")
      s = %{s | awaiting_transfer: false, call: %{s.call | destination: target}}
      {:noreply, run(reroute(s, target), s)}
    else
      {:noreply, s}
    end
  end

  # Answered and connected: the extension rung is on a call (call waiting off makes it busy).
  # Connected to a carrier: its talk time counts from now (minute caps).
  def handle_info(
        {:event, "CHANNEL_BRIDGE", _e},
        %{action: %{trunk_call: %{emergency: false} = meta}} = s
      ) do
    {:noreply, caller_lamp(%{s | talking: {meta, DateTime.utc_now()}}, "confirmed")}
  end

  def handle_info({:event, "CHANNEL_BRIDGE", _e}, %{action: %{ext_id: ext_id} = a} = s)
      when is_binary(ext_id) do
    Calls.mark_in_use(ext_id)

    s =
      s
      |> lamp(a.ext_number, a.domain, s.call.caller, "recipient", "confirmed")
      |> caller_lamp("confirmed")

    {:noreply, s}
  end

  def handle_info({:event, "CHANNEL_BRIDGE", _e}, s), do: {:noreply, caller_lamp(s, "confirmed")}

  def handle_info({:event, "CHANNEL_HANGUP_COMPLETE", e}, s) do
    if s.vm, do: VoicemailFlow.hangup(s.vm, e)
    {:stop, :normal, s |> stop_talking() |> lamps_off()}
  end

  def handle_info({:event, _name, _e}, s), do: {:noreply, s}

  ## Deciding

  # Returns the action and the tenant it was routed in.
  defp decide(call) do
    base = base_ctx()

    case Router.plan(call, Map.put(base, :tenant, Cache.tenant(call.tenant_id))) do
      {:tenant_needed, tid, did, caller} ->
        case Cache.tenant(tid) do
          nil -> {%{op: :reject, cause: "UNALLOCATED_NUMBER"}, nil}
          tenant -> {Router.plan_did(did, caller, Map.put(base, :tenant, tenant)), tid}
        end

      action ->
        {action, call.tenant_id}
    end
  rescue
    e ->
      Logger.error("call #{call.uuid}: routing failed: #{Exception.message(e)}")
      {%{op: :reject, cause: "NORMAL_TEMPORARY_FAILURE"}, call.tenant_id}
  end

  defp reroute(s, target) do
    Router.transfer(s.call, target, Map.put(base_ctx(), :tenant, Cache.tenant(s.tenant_id)))
  rescue
    e ->
      Logger.error("call #{s.call.uuid}: rerouting failed: #{Exception.message(e)}")
      %{op: :reject, cause: "NORMAL_TEMPORARY_FAILURE"}
  end

  defp base_ctx, do: %{platform: Cache.platform(), dids: Cache.dids(), in_use: Calls.in_use()}

  # The extension this call was ringing or connected to is no longer part of it.
  defp leave_current(%{action: %{ext_id: ext_id} = a} = s) when is_binary(ext_id) do
    Registry.unregister(QPBX.Telephony.InUse, ext_id)
    lamp(s, a.ext_number, a.domain, s.call.caller, "recipient", "terminated")
  end

  defp leave_current(s), do: s

  # FreeSWITCH appends to transfer_history on every transfer of the channel.
  defp transferred?(nil, _seen), do: false
  defp transferred?(history, seen), do: history != seen

  defp redirect_target(e) do
    case e["variable_sip_redirect_contact_user_0"] do
      user when is_binary(user) and user != "" -> user
      _ -> nil
    end
  end

  ## Doing

  defp run(%{op: :reject, cause: cause}, s) do
    Connection.hangup(s.call.uuid, cause)
    %{s | action: nil}
  end

  # The extension's mailbox takes a message; without one the call ends as it would have.
  defp run(%{op: :voicemail} = a, s) do
    case mailbox(s.tenant_id, a.ext_id) do
      nil ->
        run(a.otherwise, s)

      mb ->
        tenant = safe_tenant(s.tenant_id)

        info = %{
          caller_number: s.call.caller,
          caller_name: s.call.caller_name,
          extension_number: a.ext_number,
          locale: tenant && tenant.tenant.locale,
          reason: a.reason
        }

        {apps, vm} = VoicemailFlow.leave(mb, info)
        flow(apps, %{s | vm: vm, action: a})
    end
  end

  # *97: the calling phone's own mailbox, behind its PIN.
  defp run(%{op: :voicemail_menu} = a, s) do
    case s.caller_ext && mailbox(s.tenant_id, s.caller_ext.id) do
      nil ->
        run(%{op: :reject, cause: "UNALLOCATED_NUMBER"}, s)

      mb ->
        {apps, vm} = VoicemailFlow.menu(mb)
        flow(apps, %{s | vm: vm, action: a})
    end
  end

  # A dial to a carrier passes call admission first (once per destination number).
  defp run(%{op: :dial, trunk_call: %{} = meta} = action, s) do
    # A call to a carrier is outbound in its CDR, also when admission refuses it.
    Connection.execute(s.call.uuid, "set", "qpbx_direction=outbound", Ecto.UUID.generate())

    case admit_outbound(meta, s) do
      {:ok, left, s} ->
        dial(limit_duration(action, left), s)

      {:reject, cause, s} ->
        run(%{op: :reject, cause: cause}, s)
    end
  end

  defp run(%{op: :dial} = action, s), do: dial(action, s)

  defp mailbox(nil, _ext_id), do: nil

  defp mailbox(tid, ext_id) do
    Voicemail.mailbox_system(tid, ext_id)
  rescue
    e ->
      Logger.error("voicemail: mailbox lookup failed: #{Exception.message(e)}")
      nil
  end

  # Sends the voicemail flow's applications in order; the last one's completion is the next step.
  defp flow([], s), do: s

  defp flow(apps, s) do
    uuid = s.call.uuid

    id =
      Enum.reduce(apps, nil, fn {app, arg}, _ ->
        id = Ecto.UUID.generate()
        Connection.execute(uuid, app, arg, id)
        id
      end)

    %{s | pending: id}
  end

  defp dial(%{op: :dial} = action, s) do
    s =
      if action[:ext_number],
        do: lamp(s, action.ext_number, action.domain, s.call.caller, "recipient", "early"),
        else: s

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

  defp after_dial(outcome, action, s) do
    # Not answered there: that extension's lamp goes off before the next step.
    s =
      if action[:ext_number],
        do: lamp(s, action.ext_number, action.domain, s.call.caller, "recipient", "terminated"),
        else: s

    run(Map.fetch!(action, outcome), s)
  end

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
