defmodule QPBX.Telephony.ClickToCall do
  @moduledoc """
  Click-to-call and control of live calls (tenant scope).

  Click-to-call rings the extension's devices first, showing the target. When one answers,
  FreeSWITCH parks the leg and a call process starts for it as a call from that extension
  (its device login) to the target: routing, call admission, records and `call.*` events are
  those of any call the phone would have dialled. Not answered within 30 seconds: nothing more
  happens (FreeSWITCH reports the failed job and it is logged).

  Hang up and blind transfer act on a live call by its `call_id` (the caller's channel), only
  within its tenant. A transfer moves the caller's side to a new destination; the other side
  is released.
  """
  alias QPBX.Core
  alias QPBX.Core.Scope
  alias QPBX.Telephony.{Cache, Calls, Router}
  alias QPBX.Telephony.ESL.Connection

  @ring_seconds 30
  # Extension numbers, E.164 numbers and feature codes; nothing else reaches FreeSWITCH.
  @target ~r/\A(\+?[0-9]{2,20}|\*[0-9]{2,6})\z/

  @doc """
  Rings the extension, then calls `to` from it. `{:ok, call_id}` once its phones ring
  (`call_id` is the id of the call's events), or `{:error, reason}`: `:not_found`,
  `:no_devices`, `:bad_target`, `:not_connected`.
  """
  def originate(%Scope{kind: :tenant, tenant_id: tid} = scope, ext_id, to, actor) do
    to = target(scope, to)

    with true <- is_binary(to) || {:error, :bad_target},
         %{} = t <- Cache.tenant(tid) || {:error, :not_found},
         {:ok, legs, login} <- Router.click_legs(t, ext_id) do
      call_id = Ecto.UUID.generate()

      vars =
        Enum.map_join(
          [
            origination_uuid: call_id,
            origination_caller_id_number: to,
            origination_caller_id_name: to,
            originate_timeout: @ring_seconds,
            qpbx_call: "true",
            qpbx_source: "device",
            qpbx_tenant: tid,
            qpbx_auth_user: login,
            qpbx_destination: to
          ],
          ",",
          fn {k, v} -> "#{k}=#{v}" end
        )

      with {:ok, _} <- Connection.bgapi("originate {#{vars}}#{legs} &park()") do
        Core.audit(actor, "call.originate", nil, %{
          tenant_id: tid,
          extension_id: ext_id,
          to: to,
          call_id: call_id
        })

        {:ok, call_id}
      end
    end
  end

  @doc "The tenant's live calls (summaries)."
  def list(%Scope{kind: :tenant, tenant_id: tid}),
    do: Enum.filter(Calls.summaries(), &(&1.tenant_id == tid))

  def hangup(%Scope{kind: :tenant} = scope, call_id, actor) do
    with {:ok, call} <- live(scope, call_id),
         # uuid_kill, not a hangup message: FreeSWITCH queues messages behind the running
         # application (the bridge of a live call).
         {:ok, _} <- Connection.api("uuid_kill #{call.call_id} NORMAL_CLEARING") do
      Core.audit(actor, "call.hangup", nil, %{tenant_id: call.tenant_id, call_id: call.call_id})
      :ok
    end
  end

  @doc "Blind transfer of the caller's side to `to` (an extension, a number or a feature code)."
  def transfer(%Scope{kind: :tenant} = scope, call_id, to, actor) do
    to = target(scope, to)

    with true <- is_binary(to) || {:error, :bad_target},
         {:ok, call} <- live(scope, call_id),
         {:ok, _} <- Connection.api("uuid_transfer #{call.call_id} #{to} XML public") do
      Core.audit(actor, "call.transfer", nil, %{
        tenant_id: call.tenant_id,
        call_id: call.call_id,
        to: to
      })

      :ok
    end
  end

  defp live(%Scope{tenant_id: tid}, call_id) do
    case Calls.summary(call_id) do
      %{tenant_id: ^tid} = call -> {:ok, call}
      _ -> {:error, :not_found}
    end
  end

  # An extension number or E.164 as given; other forms through the tenant's number rule.
  defp target(scope, to) when is_binary(to) do
    to = String.replace(to, ~r/[\s\-().]/, "")

    cond do
      not Regex.match?(@target, to) -> nil
      String.starts_with?(to, "+") or String.starts_with?(to, "*") or byte_size(to) <= 6 -> to
      true -> local(scope, to)
    end
  end

  defp target(_, _), do: nil

  defp local(scope, to) do
    case Core.to_e164(scope, to) do
      {:ok, e164} -> e164
      _ -> to
    end
  end
end
