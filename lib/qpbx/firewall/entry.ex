defmodule QPBX.Firewall.Entry do
  @moduledoc """
  One allow or block list entry. Platform entries cover the whole installation (management
  IPs, carriers, monitoring); tenant entries are a tenant's office IPs, allowed for SIP.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias QPBX.Firewall.CIDR

  @scopes ~w(ssh sip https all)
  @kinds ~w(allow block)
  # Widest prefix a tenant may add: a tenant entry bypasses SIP bans, so it must stay narrow.
  @tenant_min_len %{v4: 24, v6: 48}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "firewall_entries" do
    field :level, :string
    field :tenant_id, :binary_id
    field :kind, :string
    field :scope, :string
    field :cidr, :string
    field :family, :string
    field :prefix_len, :integer, virtual: true
    field :expires_at, :utc_datetime
    field :reason, :string
    field :author_type, :string
    field :author_id, :binary_id
    timestamps(type: :utc_datetime)
  end

  def scopes, do: @scopes
  def kinds, do: @kinds

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:level, :tenant_id, :kind, :scope, :cidr, :expires_at, :reason])
    |> validate_required([:level, :kind, :scope, :cidr, :reason])
    |> validate_inclusion(:level, ~w(platform tenant))
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:scope, @scopes)
    |> validate_length(:reason, max: 500)
    |> normalize_cidr()
    |> validate_level()
    |> validate_future(:expires_at)
    |> unique_constraint([:level, :tenant_id, :kind, :scope, :cidr],
      name: :firewall_entries_unique
    )
  end

  defp normalize_cidr(cs) do
    case get_change(cs, :cidr) do
      nil ->
        cs

      text ->
        case CIDR.parse(text) do
          {:ok, canonical, fam, len} ->
            cs
            |> put_change(:cidr, canonical)
            |> put_change(:family, Atom.to_string(fam))
            |> put_change(:prefix_len, len)

          :error ->
            add_error(cs, :cidr, "is not a valid IP address or prefix")
        end
    end
  end

  defp validate_level(cs) do
    case get_field(cs, :level) do
      "platform" ->
        validate_change(cs, :tenant_id, fn :tenant_id, _ ->
          [tenant_id: "must be empty for platform entries"]
        end)

      "tenant" ->
        cs
        |> validate_required([:tenant_id])
        |> validate_inclusion(:kind, ["allow"], message: "tenants can only add allow entries")
        |> validate_inclusion(:scope, ["sip"], message: "tenant entries are for SIP only")
        |> validate_tenant_width()

      _ ->
        cs
    end
  end

  defp validate_tenant_width(cs) do
    with fam when is_binary(fam) <- get_change(cs, :family),
         len when is_integer(len) <- get_change(cs, :prefix_len),
         min = @tenant_min_len[String.to_existing_atom(fam)],
         true <- len < min do
      add_error(cs, :cidr, "is too wide for a tenant entry (at most /%{min})", min: min)
    else
      _ -> cs
    end
  end

  defp validate_future(cs, field) do
    validate_change(cs, field, fn ^field, at ->
      if DateTime.compare(at, DateTime.utc_now()) == :gt,
        do: [],
        else: [{field, "must be in the future"}]
    end)
  end

  @doc "Management entries: platform-level allow entries that cover SSH."
  def management?(%__MODULE__{level: "platform", kind: "allow", scope: s}),
    do: s in ["ssh", "all"]

  def management?(_), do: false

  def active?(%__MODULE__{expires_at: nil}, _now), do: true
  def active?(%__MODULE__{expires_at: at}, now), do: DateTime.compare(at, now) == :gt
end
