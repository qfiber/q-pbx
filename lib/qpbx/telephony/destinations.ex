defmodule QPBX.Telephony.Destinations do
  @moduledoc """
  Sends a call to a destination (`QPBX.Core.Destination`): an extension (with its own
  forwarding and voicemail), straight to an extension's mailbox, an outside number, or hang up.
  Returns the call process's next action, like the rest of `QPBX.Telephony.Router`. An unknown
  or missing destination refuses the call (unallocated number).
  """
  alias QPBX.Telephony.Router

  @doc """
  `dest`: `%{type, id, number}`; `caller` as in `Router`; `hops`: forwards so far (loops stop
  at the router's limit); `shown`: the tenant's number to present when the call goes out again
  (the number that was called), or nil.
  """
  def route(dest, caller, ctx, hops, shown \\ nil)

  def route(%{type: type, id: id}, caller, %{tenant: t} = ctx, hops, _shown)
      when type in ["extension", "voicemail"] do
    case Enum.find(t.extensions, &(&1.id == id)) do
      nil -> Router.reject("UNALLOCATED_NUMBER")
      ext when type == "extension" -> Router.ring_extension(ext, caller, ctx, hops)
      ext -> Router.voicemail(ext, :unavailable, Router.reject("NO_ANSWER"))
    end
  end

  def route(%{type: "external", number: e164}, caller, ctx, hops, shown)
      when is_binary(e164) do
    if hops < Router.max_hops(),
      do: Router.outbound(e164, %{caller | external: shown || caller.external}, ctx),
      else: Router.reject("UNALLOCATED_NUMBER")
  end

  def route(%{type: "hangup"}, _caller, _ctx, _hops, _shown), do: Router.reject("NORMAL_CLEARING")
  def route(_dest, _caller, _ctx, _hops, _shown), do: Router.reject("UNALLOCATED_NUMBER")

  @doc "A number's (DID's) destination fields as a destination."
  def of_did(did),
    do: %{
      type: Map.get(did, :destination_type),
      id: Map.get(did, :destination_id),
      number: Map.get(did, :destination_number)
    }
end
