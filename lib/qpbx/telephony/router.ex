defmodule QPBX.Telephony.Router do
  @moduledoc """
  Decides what happens to a new call. Pure: takes the call and a configuration snapshot, and
  returns an action tree the call process walks:

    * `%{op: :dial, dial: dial_string, timeout: seconds, busy: action, no_answer: action, failed: action}`
      answered ends the call normally; otherwise the matching branch runs.
    * `%{op: :reject, cause: freeswitch_cause}`

  Covered: phone to extension (all its devices ring), phone to an outside number (outbound
  route, trunks in failover order, caller ID per trunk), emergency numbers, carrier to a
  number (DID, backup numbers, its destination), and the extension features: do not disturb,
  call waiting, forwarding (always, busy, no answer) and follow-me.
  """
  alias QPBX.Core.Numbers

  @max_hops 5
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

    cond do
      emergency = Enum.find(ctx.platform.emergency, &(&1.number == dialed)) ->
        emergency_call(emergency, caller, ctx)

      ext = extension(t, dialed) ->
        ring_extension(ext, caller, ctx, 0)

      true ->
        case Numbers.to_e164(dialed, t.rule) do
          {:ok, e164} -> to_number(e164, caller, ctx, 0)
          :error -> reject("UNALLOCATED_NUMBER")
        end
    end
  end

  defp emergency_call(route, caller, ctx) do
    case ctx.platform.trunks[route.trunk_id] do
      %{enabled: true} = trunk ->
        trunk_dial([{trunk, route.number}], caller.external, reject("NORMAL_TEMPORARY_FAILURE"))

      _ ->
        reject("NORMAL_TEMPORARY_FAILURE")
    end
  end

  # An E.164 number: one of the tenant's own (handled inside), or out through a route.
  defp to_number(e164, caller, %{tenant: t} = ctx, hops) do
    case Enum.find(t.dids, &(&1.number == e164)) do
      %{} = did ->
        did_destination(
          main_did(did, ctx),
          %{caller | number: caller.external || caller.number},
          ctx,
          hops
        )

      nil ->
        outbound(e164, caller, ctx)
    end
  end

  defp outbound(e164, caller, %{tenant: t} = ctx) do
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

        if trunks == [],
          do: reject("NO_ROUTE_DESTINATION"),
          else: trunk_dial(trunks, caller.external, reject("NORMAL_TEMPORARY_FAILURE"))
    end
  end

  # Trunks in order: busy or no answer is final; a carrier failure moves to the next trunk.
  defp trunk_dial([], _cid, last), do: last

  defp trunk_dial([{trunk, number} | rest], cid, last) do
    shown = if trunk.caller_id_mode == "own_number", do: trunk.default_caller_id, else: cid
    # The name is the number too: never an internal name or login towards a carrier.
    vars = %{
      "sip_h_X-QPBX-Trunk-Edge" => trunk.edge_id,
      "origination_caller_id_number" => shown,
      "origination_caller_id_name" => shown
    }

    %{
      op: :dial,
      dial: leg(vars, "sofia/qpbx/#{number}@127.0.0.1:5060"),
      timeout: 60,
      busy: reject("USER_BUSY"),
      no_answer: reject("NO_ANSWER"),
      failed: trunk_dial(rest, cid, last)
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
  def plan_did(did, caller, ctx), do: did_destination(did, caller, ctx, 0)

  defp did_destination(
         %{destination_type: "extension", destination_id: id},
         caller,
         %{tenant: t} = ctx,
         hops
       ) do
    case Enum.find(t.extensions, &(&1.id == id)) do
      nil -> reject("UNALLOCATED_NUMBER")
      ext -> ring_extension(ext, caller, ctx, hops)
    end
  end

  defp did_destination(
         %{destination_type: "external", destination_number: e164, number: did_number},
         caller,
         ctx,
         hops
       )
       when hops < @max_hops do
    # Forwarded out: the carrier sees the tenant's number that was called.
    outbound(e164, %{caller | external: did_number}, ctx)
  end

  defp did_destination(_did, _caller, _ctx, _hops), do: reject("UNALLOCATED_NUMBER")

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

  defp ring_extension(_ext, _caller, _ctx, hops) when hops >= @max_hops,
    do: reject("NO_ROUTE_DESTINATION")

  defp ring_extension(ext, caller, %{tenant: t} = ctx, hops) do
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

  # Not answered: follow-me numbers, then forward-on-no-answer, then unavailable
  # (voicemail arrives with 2-7).
  defp after_no_answer(ext, caller, ctx, hops) do
    final =
      if ext.forward_no_answer,
        do: forward(ext.forward_no_answer, caller, ctx, hops + 1, reject("NO_ANSWER")),
        else: reject("NO_ANSWER")

    if ext.follow_me_enabled and ext.follow_me_numbers != [] do
      case follow_me_dial(ext, caller, ctx) do
        nil ->
          final

        dial ->
          %{
            op: :dial,
            dial: dial,
            timeout: ext.no_answer_seconds,
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
      else: reject("USER_BUSY")
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
            %{"sip_route_uri" => @edge},
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
          %{"sip_h_X-QPBX-Trunk-Edge" => trunk.edge_id, "origination_caller_id_number" => cid},
          "sofia/qpbx/#{Numbers.carrier_number(route, number)}@127.0.0.1:5060"
        )
      ]
    else
      _ -> []
    end
  end

  @doc "The extension a device belongs to (its number and domain, for the caller's busy lamp)."
  def caller_extension(nil, _auth_user), do: nil

  def caller_extension(t, auth_user) do
    case device_extension(t, auth_user) do
      nil -> nil
      ext -> %{number: ext.number, domain: t.tenant.sip_domain}
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

  defp reject(cause), do: %{op: :reject, cause: cause}
end
