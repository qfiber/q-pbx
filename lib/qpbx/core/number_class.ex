defmodule QPBX.Core.NumberClass do
  @moduledoc """
  Platform list: E.164 prefixes and their destination class (local, mobile, international,
  premium). The longest matching prefix wins; a number matching none is international if it is
  outside the home country, local otherwise. High-cost prefixes are entries with class premium.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias QPBX.Core.{E164, Plan}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "number_classes" do
    field :prefix, :string
    field :class, :string
    field :note, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(nc, attrs) do
    nc
    |> cast(attrs, [:prefix, :class, :note])
    |> validate_required([:prefix, :class])
    |> E164.validate_prefixes(:prefix)
    |> validate_inclusion(:class, Plan.destination_classes())
    |> validate_length(:note, max: 200)
    |> unique_constraint(:prefix)
  end
end
