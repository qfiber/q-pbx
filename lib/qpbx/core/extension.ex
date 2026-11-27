defmodule QPBX.Core.Extension do
  @moduledoc "An internal number of a tenant, with its call features. Its devices ring together."
  use Ecto.Schema
  import Ecto.Changeset
  alias QPBX.Core.E164

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "extensions" do
    field :tenant_id, :binary_id
    field :number, :string
    field :name, :string
    field :external_caller_id, :string
    field :dnd, :boolean, default: false
    field :call_waiting, :boolean, default: true
    field :forward_always, :string
    field :forward_busy, :string
    field :forward_no_answer, :string
    field :no_answer_seconds, :integer, default: 20
    field :follow_me_enabled, :boolean, default: false
    field :follow_me_numbers, {:array, :string}, default: []
    has_many :devices, QPBX.Core.Device
    timestamps(type: :utc_datetime)
  end

  @fields ~w(number name external_caller_id dnd call_waiting forward_always forward_busy
             forward_no_answer no_answer_seconds follow_me_enabled follow_me_numbers)a

  def changeset(ext, attrs) do
    ext
    |> cast(attrs, @fields)
    |> validate_required([:number, :name])
    # 2 to 6 digits, not starting with 0 (0 dials out in most countries) or * (feature codes).
    |> validate_format(:number, ~r/\A[1-9]\d{1,5}\z/,
      message: "2 to 6 digits, not starting with 0"
    )
    |> validate_length(:name, max: 100)
    |> E164.validate(:external_caller_id)
    |> E164.validate_target(:forward_always)
    |> E164.validate_target(:forward_busy)
    |> E164.validate_target(:forward_no_answer)
    |> E164.validate_targets(:follow_me_numbers)
    |> validate_number(:no_answer_seconds,
      greater_than_or_equal_to: 5,
      less_than_or_equal_to: 120
    )
    |> validate_length(:follow_me_numbers, max: 5)
    |> unique_constraint([:tenant_id, :number], error_key: :number)
  end
end
