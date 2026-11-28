defmodule QPBX.Core.Destination do
  @moduledoc """
  Where a call can go, the one kind used everywhere a call is sent on: a number (DID), and
  later IVR options, ring groups' and time conditions' outcomes. Stored as three fields on the
  record that points (`<prefix>_type`, `<prefix>_id`, `<prefix>_number`), so "what points at
  this extension" stays a plain query.

  Kinds: `extension` (ring it, with its own forwarding and voicemail), `voicemail` (straight to
  an extension's mailbox), `external` (an outside number, E.164), `hangup`. Ring groups, IVRs,
  time conditions and fax boxes join with their tasks. An empty type means nowhere: the call
  is refused.
  """
  import Ecto.Changeset
  import Ecto.Query
  alias QPBX.Core.{E164, Extension}
  alias QPBX.Repo

  @types ~w(extension voicemail external hangup)

  def types, do: @types

  @doc "Kinds that point at a record by id (the rest use a number, or nothing)."
  def by_id?(type), do: type in ~w(extension voicemail)

  @doc """
  Validates and tidies a destination held in `fields` (`type:`, `id:`, `number:`; the defaults
  are a number's `destination_*` fields): the kind is known, the record is the tenant's, an
  outside number is E.164, and fields the kind does not use are cleared.
  """
  def validate(cs, tenant_id, fields \\ []) do
    t = Keyword.get(fields, :type, :destination_type)
    i = Keyword.get(fields, :id, :destination_id)
    n = Keyword.get(fields, :number, :destination_number)
    cs = validate_inclusion(cs, t, @types)

    case get_field(cs, t) do
      type when type in ~w(extension voicemail) ->
        cs |> validate_required([i]) |> put_change(n, nil) |> own_extension(i, tenant_id)

      "external" ->
        cs |> validate_required([n]) |> E164.validate(n) |> put_change(i, nil)

      _ ->
        cs |> put_change(i, nil) |> put_change(n, nil)
    end
  end

  defp own_extension(cs, field, tid) do
    id = get_field(cs, field)

    if is_nil(id) or
         Repo.exists?(from e in Extension, where: e.id == ^id and e.tenant_id == ^tid),
       do: cs,
       else: add_error(cs, field, "not an extension of this tenant")
  end
end
