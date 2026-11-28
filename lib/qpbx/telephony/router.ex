defmodule QPBX.Telephony.Router do
  @moduledoc """
  Decides what happens to a new call. Pure: takes the call and a configuration snapshot, and
  returns an action tree the call process walks:

    * `%{op: :dial, dial: dial_string, timeout: seconds, busy: action, no_answer: action, failed: action}`
      answered ends the call normally; otherwise the matching branch runs.
    * `%{op: :reject, cause: freeswitch_cause}`
    * `%{op: :voicemail, ext_id, ext_number, reason: :busy | :unavailable, otherwise: action}`
      the extension's mailbox takes a message (`otherwise` when it has none);
    * `%{op: :voicemail_menu}` the caller's own mailbox (`*97`).

  Covered: phone to extension (all its devices ring), phone to an outside number (outbound
  route, trunks in failover order, caller ID per trunk), emergency numbers, carrier to a
  number (DID, backup numbers, its destination), and the extension features: do not disturb,
  call waiting, forwarding (always, busy, no answer) and follow-me.
  """
  alias QPBX.Core.Numbers
  alias QPBX.Telephony.Destinations

  @max_hops 5
  # A diagnostic feature code ahead of phase 4's full set: answers, plays a prompt, echoes.
  @echo "*43"
  @voicemail "*97"
  # Where FreeSWITCH reaches phones and carriers: always through Kamailio.
  @edge "sip:127.0.0.1:5060"

  @type call :: %{
          required(:source) => :device | :trunk,
          required(:destination) => String.t(),
          optional(:tenant_id) => String.t() | nil,
          optional(:auth_user) => String.t() | nil,
          optional(:trunk_id) => String.t() | nil,
          optional(:caller) => String.t() | nil
        }

  @doc """
  `ctx`: `%{tenant: tenant snapshot | nil, platform: platform snapshot, dids: %{number => did},
  in_use: MapSet of extension ids on a call}`.
  """
  def plan(%{source: :device} = call, %{tenant: t} = ctx) when not is_nil(t) do
    case device_extension(t, call.auth_user) do
      nil -> reject("CALL_REJECTED")
      from -> from_device(call, from, ctx)
    end
  end

  def plan(%{source: :trunk} = call, ctx), do: from_trunk(call, ctx)
  def plan(_call, _ctx), do: reject("CALL_REJECTED")

  ## From a phone

  defp from_device(call, from, %{tenant: t} = ctx) do
    dialed = call.destination
    caller = %{number: from.number, name: from.name, external: outside_caller_id(from, t)}

    case Enum.find(ctx.platform.emergency, &(&1.number == dialed)) do
      nil -> plan_target(dialed, caller, ctx)
      emergency -> emergency_call(emergency, caller, ctx)
    end
  end

  @doc """
  Where a call goes when it is transferred (a REFER) or redirected (a 302) to `target`: the
  same rules as a phone dialling it, with the call's original caller. A transferred carrier
  call stays within the number's tenant.
  """
  def transfer(%{source: :device} = call, target, ctx),
    do: plan(%{call | destination: target}, ctx)

  def transfer(%{source: :trunk} = call, target, %{tenant: t} = ctx) when not is_nil(t),
    do: plan_target(target, caller_from(call.caller, t.rule), ctx)

  def transfer(_call, _target, _ctx), do: reject("CALL_REJECTED")

  # A destination inside a tenant: the echo test, an extension, or a number.
  defp plan_target(@echo, _caller, _ctx), do: echo()
  defp plan_target(@voicemail, _caller, _ctx), do: %{op: :voicemail_menu}

  defp plan_target(target, caller, %{tenant: t} = ctx) do
    case extension(t, target) do
      %{} = ext ->
        ring_extension(ext, caller, ctx, 0)

      nil ->
        case Numbers.to_e164(target, t.rule) do
          {:ok, e164} -> to_number(e164, caller, ctx, 0)
          :error -> reject("UNALLOCATED_NUMBER")
        end
    end
  end

  # The echo test: a FreeSWITCH loopback channel that plays a short tone prompt, then echoes
  # (QPBX.Telephony.Dialplan serves it to loopback channels only). Bridged like any answered
  # call, so transfers to and from it work.
  defp echo do
    %{
      op: :dial,
      dial: "loopback/#{QPBX.Telephony.Dialplan.echo_destination()}/public/XML",
      timeout: 10,
      busy: reject("USER_BUSY"),
      no_answer: reject("NO_ANSWER"),
      failed: reject("NORMAL_TEMPORARY_FAILURE")
    }
  end

  defp emergency_call(route, caller, ctx) do
    case ctx.platform.trunks[route.trunk_id] do
      %{enabled: true} = trunk ->
        meta = %{e164: route.number, class: "emergency", emergency: true}

        trunk_dial(
          [{trunk, route.number}],
          caller.external,
          reject("NORMAL_TEMPORARY_FAILURE"),
          meta
        )

      _ ->
        reject("NORMAL_TEMPORARY_FAILURE")
    end
  end

  # An E.164 number: one of the tenant's own (handled inside), or out through a route.
  defp to_number(e164, caller, %{tenant: t} = ctx, hops) do
    case Enum.find(t.dids, &(&1.number == e164)) do
      %{} = did ->
        main = main_did(did, ctx)

        Destinations.route(
          Destinations.of_did(main),
          %{caller | number: caller.external || caller.number},
          ctx,
          hops,
          Map.get(main, :number)
        )

      nil ->
        outbound(e164, caller, ctx)
    end
  end

  @doc false
  def outbound(e164, caller, %{tenant: t} = ctx) do
    case Numbers.select_route(e164, t.routes) do
      nil ->
        reject("NO_ROUTE_DESTINATION")

      route ->
        number = Numbers.carrier_number(route, e164)

        trunks =
          for id <- route.trunk_ids,
              trunk = ctx.platform.trunks[id],
              trunk.enabled,
              do: {trunk, number}

        # Call admission checks each trunk attempt against the number's destination class.
        meta = %{
          e164: e164,
          class: Numbers.classify(e164, t.rule, ctx.platform.classes),
          emergency: false
        }

        if trunks == [],
          do: reject("NO_ROUTE_DESTINATION"),
          else: trunk_dial(trunks, caller.external, reject("NORMAL_TEMPORARY_FAILURE"), meta)
    end
  end

  # Trunks in order: busy or no answer is final; a carrier failure moves to the next trunk.
  defp trunk_dial([], _cid, last, _meta), do: last

  defp trunk_dial([{trunk, number} | rest], cid, last, meta) do
    shown = if trunk.caller_id_mode == "own_number", do: trunk.default_caller_id, else: cid
    # The name is the number too: never an internal name or login towards a carrier.
    vars = %{
      "sip_h_X-QPBX-Trunk-Edge" => trunk.edge_id,
      "origination_caller_id_number" => shown,
      "origination_caller_id_name" => shown,
      # For the CDR of this leg.
      "qpbx_trunk_id" => trunk.id,
      "qpbx_direction" => "outbound",
      "qpbx_callee" => meta.e164
    }

    %{
      op: :dial,
      dial: leg(vars, "sofia/qpbx/#{number}@127.0.0.1:5060"),
      timeout: 60,
      trunk_call: meta,
      busy: reject("USER_BUSY"),
      no_answer: reject("NO_ANSWER"),
      failed: trunk_dial(rest, cid, last, meta)
    }
  end

  ## From a carrier

  defp from_trunk(call, ctx) do
    trunk = ctx.platform.trunks[call.trunk_id]
    rule = (ctx.tenant && ctx.tenant.rule) || ctx.platform.default_rule

    with %{} <- trunk,
         %{} = did <- find_did(call.destination, rule, ctx.dids),
         # A tenant's own trunk delivers only that tenant's numbers.
         true <- is_nil(trunk.tenant_id) or trunk.tenant_id == did.tenant_id,
         %{tenant_id: tid} = main when not is_nil(tid) <- main_did(did, ctx) do
      {:tenant_needed, tid, main, caller_from(call.caller, rule)}
    else
      _ -> reject("UNALLOCATED_NUMBER")
    end
  end

  @doc """
  Second step for calls from carriers, once the DID's tenant snapshot is loaded (`plan/2`
  returned `{:tenant_needed, tenant_id, did, caller}`).
  """
  def plan_did(did, caller, ctx),
    do: Destinations.route(Destinations.of_did(did), caller, ctx, 0, Map.get(did, :number))

  defp find_did(dest, rule, dids) do
    digits = String.trim_leading(dest, "+")

    candidates =
      ["+" <> digits | for({:ok, n} <- [Numbers.to_e164(dest, rule)], do: n)]

    Enum.find_value(candidates, &dids[&1])
  end

  defp main_did(%{alias_of_id: nil} = did, _ctx), do: did

  defp main_did(%{alias_of_id: id}, ctx),
    do: Enum.find_value(ctx.dids, fn {_n, d} -> d.id == id && d end)

  # How a carrier's caller shows on phones: the national form at home.
  defp caller_from(nil, _rule), do: %{number: "anonymous", name: nil, external: nil}

  defp caller_from(number, rule) do
    shown =
      case Numbers.to_e164(number, rule) do
        {:ok, e164} -> Numbers.display(e164, rule)
        :error -> number
      end

    %{number: shown, name: nil, external: nil}
  end

  ## Extensions and their features

  @doc false
  def max_hops, do: @max_hops

  @doc false
  def ring_extension(_ext, _caller, _ctx, hops) when hops >= @max_hops,
    do: reject("NO_ROUTE_DESTINATION")

  def ring_extension(ext, caller, %{tenant: t} = ctx, hops) do
    cond do
      ext.forward_always ->
        forward(ext.forward_always, caller, ctx, hops + 1, reject("NO_ROUTE_DESTINATION"))

      ext.dnd ->
        on_busy(ext, caller, ctx, hops)

      not ext.call_waiting and MapSet.member?(ctx.in_use, ext.id) ->
        on_busy(ext, caller, ctx, hops)

      true ->
        ring_devices(ext, caller, t, ctx, hops)
    end
  end

  defp ring_devices(ext, caller, t, ctx, hops) do
    no_answer = after_no_answer(ext, caller, ctx, hops)

    case devices_dial(ext, caller, t) do
      nil ->
        no_answer

      dial ->
        %{
          op: :dial,
          dial: dial,
          timeout: ext.no_answer_seconds,
          # Answered: the extension is on a call (call waiting off makes it busy); its busy lamp.
          ext_id: ext.id,
          ext_number: ext.number,
          domain: t.tenant.sip_domain,
          busy: on_busy(ext, caller, ctx, hops),
          no_answer: no_answer,
          failed: no_answer
        }
    end
  end

  # Not answered: follow-me numbers, then forward-on-no-answer, then voicemail.
  defp after_no_answer(ext, caller, ctx, hops) do
    final =
      if ext.forward_no_answer,
        do: forward(ext.forward_no_answer, caller, ctx, hops + 1, reject("NO_ANSWER")),
        else: voicemail(ext, :unavailable, reject("NO_ANSWER"))

    if ext.follow_me_enabled and ext.follow_me_numbers != [] do
      case follow_me_dial(ext, caller, ctx) do
        nil ->
          final

        dial ->
          %{
            op: :dial,
            dial: dial,
            timeout: ext.no_answer_seconds,
            trunk_call: follow_me_meta(ext, ctx),
            busy: final,
            no_answer: final,
            failed: final
          }
      end
    else
      final
    end
  end

  defp on_busy(ext, caller, ctx, hops) do
    if ext.forward_busy,
      do: forward(ext.forward_busy, caller, ctx, hops + 1, reject("USER_BUSY")),
      else: voicemail(ext, :busy, reject("USER_BUSY"))
  end

  # A forwarding target: an extension (with its own features) or an outside number.
  defp forward(target, caller, %{tenant: t} = ctx, hops, otherwise) do
    cond do
      hops >= @max_hops ->
        otherwise

      ext = extension(t, target) ->
        ring_extension(ext, caller, ctx, hops)

      String.starts_with?(target, "+") ->
        # Out to the carrier: the tenant's number is shown (carriers refuse foreign caller IDs).
        outbound(target, %{caller | external: caller.external || first_did(t)}, ctx)

      true ->
        otherwise
    end
  end

  defp devices_dial(ext, caller, t) do
    case device_legs(ext, t) do
      [] -> nil
      legs -> globals(caller) <> Enum.join(legs, ",")
    end
  end

  # shortcut: an outside follow-me number uses the first trunk of its route only (no failover
  # inside a simultaneous ring); chain them if a tenant needs it.
  @risk ~w(local mobile international premium)

  # Follow-me rings outside numbers too: admission checks the riskiest of them (nil: none).
  defp follow_me_meta(ext, %{tenant: t} = ctx) do
    outside =
      for n <- ext.follow_me_numbers, is_nil(extension(t, n)), String.starts_with?(n, "+"), do: n

    case outside do
      [] ->
        nil

      numbers ->
        numbers
        |> Enum.map(
          &%{
            e164: &1,
            class: Numbers.classify(&1, t.rule, ctx.platform.classes),
            emergency: false
          }
        )
        |> Enum.max_by(&Enum.find_index(@risk, fn c -> c == &1.class end))
    end
  end

  defp follow_me_dial(ext, caller, %{tenant: t} = ctx) do
    legs =
      Enum.flat_map(ext.follow_me_numbers, fn n ->
        case extension(t, n) do
          %{} = other -> device_legs(other, t)
          nil -> follow_me_outside(n, caller, ctx)
        end
      end)

    if legs == [], do: nil, else: globals(caller) <> Enum.join(legs, ",")
  end

  defp device_legs(ext, t) do
    for d <- ext.devices,
        do:
          leg(
            %{"sip_route_uri" => @edge, "qpbx_callee" => ext.number},
            "sofia/qpbx/#{d.sip_credential.username}@#{t.tenant.sip_domain}"
          )
  end

  defp follow_me_outside(number, caller, %{tenant: t} = ctx) do
    with %{} = route <- Numbers.select_route(number, t.routes),
         [id | _] <- route.trunk_ids,
         %{enabled: true} = trunk <- ctx.platform.trunks[id] do
      cid =
        if trunk.caller_id_mode == "own_number",
          do: trunk.default_caller_id,
          else: caller.external || first_did(t)

      [
        leg(
          %{
            "sip_h_X-QPBX-Trunk-Edge" => trunk.edge_id,
            "origination_caller_id_number" => cid,
            "qpbx_trunk_id" => trunk.id,
            "qpbx_direction" => "outbound",
            "qpbx_callee" => number
          },
          "sofia/qpbx/#{Numbers.carrier_number(route, number)}@127.0.0.1:5060"
        )
      ]
    else
      _ -> []
    end
  end

  @doc """
  Click-to-call's first leg: the extension's devices (rung at once) and one of its device
  logins (the parked leg calls as that device). `{:ok, legs, login}` or `{:error, reason}`.
  """
  def click_legs(t, ext_id) do
    case Enum.find(t.extensions, &(&1.id == ext_id)) do
      nil -> {:error, :not_found}
      %{devices: []} -> {:error, :no_devices}
      ext -> {:ok, Enum.join(device_legs(ext, t), ","), hd(ext.devices).sip_credential.username}
    end
  end

  @doc "The extension a device belongs to (its number and domain, for the caller's busy lamp)."
  def caller_extension(nil, _auth_user), do: nil

  def caller_extension(t, auth_user) do
    case device_extension(t, auth_user) do
      nil -> nil
      ext -> %{id: ext.id, number: ext.number, domain: t.tenant.sip_domain}
    end
  end

  ## Helpers

  defp device_extension(t, auth_user) do
    Enum.find(t.extensions, fn e ->
      Enum.any?(e.devices, &(&1.sip_credential.username == auth_user))
    end)
  end

  defp extension(t, number), do: Enum.find(t.extensions, &(&1.number == number))

  defp outside_caller_id(ext, t), do: ext.external_caller_id || first_did(t)

  defp first_did(t) do
    case Enum.filter(t.dids, &is_nil(&1.alias_of_id)) |> Enum.sort_by(& &1.number) do
      [d | _] -> d.number
      [] -> nil
    end
  end

  # Caller ID for the legs to phones; the call's own a-leg variables are set by the call process.
  defp globals(caller) do
    vars = %{
      "origination_caller_id_number" => caller.number,
      "origination_caller_id_name" => caller.name || caller.number
    }

    "{" <> encode(vars) <> "}"
  end

  defp leg(vars, endpoint), do: "[" <> encode(vars) <> "]" <> endpoint

  # Values are ours (numbers, names, ids); names may hold commas or brackets, which would break
  # the dial string, so those are removed.
  defp encode(vars) do
    vars
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.sort()
    |> Enum.map_join(",", fn {k, v} ->
      "#{k}=#{v |> to_string() |> String.replace(~r/[,\[\]{}'"\\]/, "")}"
    end)
  end

  @doc false
  def reject(cause), do: %{op: :reject, cause: cause}

  @doc false
  def voicemail(ext, reason, otherwise),
    do: %{
      op: :voicemail,
      ext_id: ext.id,
      ext_number: ext.number,
      reason: reason,
      otherwise: otherwise
    }
end
