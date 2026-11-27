defmodule QPBX.Core.OutboundRoute do
  @moduledoc """
  Which trunks carry calls to E.164 numbers starting with one of `prefixes` (empty: any
  number). Routes are tried by `position`; within a route its trunks are tried in order
  (carrier failover). `strip_digits` and `add_prefix` rewrite the number for the carrier.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias QPBX.Core.{E164, Plan}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "outbound_routes" do
    field :tenant_id, :binary_id
    field :name, :string
    field :prefixes, {:array, :string}, default: []
    field :position, :integer, default: 0
    field :destination_class, :string
    field :strip_digits, :integer, default: 0
    field :add_prefix, :string, default: ""
    field :enabled, :boolean, default: true
    field :trunk_ids, {:array, :binary_id}, virtual: true, default: []

    has_many :route_trunks, QPBX.Core.RouteTrunk,
      foreign_key: :route_id,
      preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def changeset(route, attrs) do
    route
    |> cast(attrs, [
      :name,
      :prefixes,
      :position,
      :destination_class,
      :strip_digits,
      :add_prefix,
      :enabled,
      :trunk_ids
    ])
    |> validate_required([:name, :destination_class])
    |> validate_length(:name, max: 100)
    |> E164.validate_prefixes(:prefixes)
    |> validate_inclusion(:destination_class, Plan.destination_classes())
    |> validate_number(:strip_digits, greater_than_or_equal_to: 0, less_than: 16)
    |> validate_format(:add_prefix, ~r/\A\+?\d{0,10}\z/, message: "digits, optionally after +")
    |> validate_length(:trunk_ids, min: 1, message: "pick at least one trunk")
  end
end
