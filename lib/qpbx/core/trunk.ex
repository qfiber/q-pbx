defmodule QPBX.Core.Trunk do
  @moduledoc """
  A carrier connection. Platform trunks (no tenant) are shared carriers; tenant trunks bring
  the tenant's own carrier. Authenticated by source IP or by registration (username and an
  encrypted password, which Kamailio needs in clear to register).
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias QPBX.Core.{E164, TrunkAddress}

  @auth_modes ~w(ip registration)
  @codecs ~w(PCMA PCMU G722 G729 opus)
  @fax_modes ~w(t38 t38_passthrough g711)
  # tenant_numbers: the trunk may present the tenant's numbers, even ones held at another
  # carrier; own_number: the carrier allows only its own number (default_caller_id).
  @caller_id_modes ~w(tenant_numbers own_number)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "trunks" do
    field :tenant_id, :binary_id
    # Set by the database; Kamailio's dispatcher set number for this trunk.
    field :edge_id, :integer, writable: :never, read_after_writes: true
    field :name, :string
    field :auth_mode, :string
    field :username, :string
    field :password, QPBX.Core.Encrypted.Binary, redact: true
    field :codecs, {:array, :string}, default: ["PCMA", "PCMU"]
    field :fax_mode, :string, default: "t38"
    field :ecm, :boolean, default: true
    field :max_channels, :integer
    field :caller_id_mode, :string, default: "tenant_numbers"
    field :default_caller_id, :string
    field :enabled, :boolean, default: true
    has_many :addresses, TrunkAddress, on_replace: :delete, preload_order: [asc: :priority]
    timestamps(type: :utc_datetime)
  end

  def codecs, do: @codecs
  def fax_modes, do: @fax_modes
  def auth_modes, do: @auth_modes
  def caller_id_modes, do: @caller_id_modes

  def changeset(trunk, attrs) do
    trunk
    |> cast(attrs, ~w(name auth_mode username password codecs fax_mode ecm max_channels
                      caller_id_mode default_caller_id enabled)a)
    |> validate_required([:name, :auth_mode])
    |> validate_length(:name, max: 100)
    |> validate_inclusion(:auth_mode, @auth_modes)
    |> validate_subset(:codecs, @codecs)
    |> validate_length(:codecs, min: 1)
    |> validate_inclusion(:fax_mode, @fax_modes)
    |> validate_inclusion(:caller_id_mode, @caller_id_modes)
    |> validate_number(:max_channels, greater_than: 0)
    |> E164.validate(:default_caller_id)
    |> require_when(:auth_mode, "registration", [:username, :password])
    |> require_when(:caller_id_mode, "own_number", [:default_caller_id])
    |> cast_assoc(:addresses,
      with: &TrunkAddress.changeset(&1, &2, trunk.tenant_id),
      required: true,
      sort_param: :addresses_sort,
      drop_param: :addresses_drop
    )
  end

  defp require_when(cs, field, value, required),
    do: if(get_field(cs, field) == value, do: validate_required(cs, required), else: cs)
end
