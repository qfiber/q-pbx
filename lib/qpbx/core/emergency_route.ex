defmodule QPBX.Core.EmergencyRoute do
  @moduledoc """
  A short emergency number of the operator's country (for example 100, 101, 102, 112) and the
  platform trunk that always carries it. Emergency calls skip spend and minute limits but are
  logged.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "emergency_routes" do
    field :number, :string
    field :trunk_id, :binary_id
    field :enabled, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  def changeset(route, attrs) do
    route
    |> cast(attrs, [:number, :trunk_id, :enabled])
    |> validate_required([:number, :trunk_id])
    |> validate_format(:number, ~r/\A\d{2,6}\z/, message: "2 to 6 digits")
    |> unique_constraint(:number)
    |> foreign_key_constraint(:trunk_id)
  end
end
