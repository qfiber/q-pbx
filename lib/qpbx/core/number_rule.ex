defmodule QPBX.Core.NumberRule do
  @moduledoc """
  How people dial and see numbers: country code, national (trunk) prefix, international
  prefixes and an optional default area code for short local numbers. One platform row (no
  tenant) is the default; a tenant may override it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "number_rules" do
    field :tenant_id, :binary_id
    field :country_code, :string
    field :national_prefix, :string, default: "0"
    field :international_prefixes, {:array, :string}, default: ["00"]
    field :area_code, :string
    timestamps(type: :utc_datetime)
  end

  @doc "Israel: +972, national prefix 0, international 00 and the carrier codes 01x."
  def israel_default do
    %__MODULE__{
      country_code: "972",
      national_prefix: "0",
      international_prefixes: ~w(00 012 013 014 015 018 019)
    }
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:country_code, :national_prefix, :international_prefixes, :area_code])
    |> validate_required([:country_code])
    |> validate_format(:country_code, ~r/\A[1-9]\d{0,2}\z/, message: "1 to 3 digits, e.g. 972")
    |> validate_format(:national_prefix, ~r/\A\d{0,2}\z/)
    |> validate_format(:area_code, ~r/\A[1-9]\d{0,4}\z/,
      message: "digits without the national prefix, e.g. 2"
    )
    |> validate_length(:international_prefixes, min: 1)
    |> validate_change(:international_prefixes, fn _, l ->
      if Enum.all?(l, &Regex.match?(~r/\A\d{2,4}\z/, &1)),
        do: [],
        else: [international_prefixes: "2 to 4 digits each"]
    end)
    |> unique_constraint(:tenant_id)
  end
end
