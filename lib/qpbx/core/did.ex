defmodule QPBX.Core.Did do
  @moduledoc """
  A phone number (E.164) the platform holds at a carrier trunk and assigns to a tenant, who
  points it at a destination. A backup number (`alias_of_id`) comes from another carrier and
  routes exactly like its main number; the main number's carrier must forward to it when
  Q-PBX does not answer.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias QPBX.Core.E164

  # Phase 2 destinations; ring groups, IVRs, queues and fax boxes come with their phases.
  @destination_types ~w(extension external)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "dids" do
    field :number, :string
    field :tenant_id, :binary_id
    field :trunk_id, :binary_id
    field :destination_type, :string
    field :destination_id, :binary_id
    field :destination_number, :string
    belongs_to :alias_of, __MODULE__
    has_many :aliases, __MODULE__, foreign_key: :alias_of_id
    timestamps(type: :utc_datetime)
  end

  def destination_types, do: @destination_types

  @doc "Platform side: the number, its carrier trunk, its tenant, or the main number it backs up."
  def platform_changeset(did, attrs) do
    did
    |> cast(attrs, [:number, :trunk_id, :tenant_id, :alias_of_id])
    |> validate_required([:number, :trunk_id])
    |> E164.validate(:number)
    |> unique_constraint(:number)
    |> foreign_key_constraint(:trunk_id)
    |> foreign_key_constraint(:tenant_id)
  end

  @doc "Tenant side: where calls to the number go. A backup number has no destination of its own."
  def destination_changeset(did, attrs) do
    did
    |> cast(attrs, [:destination_type, :destination_id, :destination_number])
    |> validate_inclusion(:destination_type, @destination_types)
    |> then(fn cs ->
      case get_field(cs, :destination_type) do
        "extension" ->
          cs |> validate_required([:destination_id]) |> put_change(:destination_number, nil)

        "external" ->
          cs
          |> validate_required([:destination_number])
          |> E164.validate(:destination_number)
          |> put_change(:destination_id, nil)

        nil ->
          cs |> put_change(:destination_id, nil) |> put_change(:destination_number, nil)

        _ ->
          cs
      end
    end)
  end
end
