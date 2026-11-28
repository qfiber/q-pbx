defmodule QPBX.Telephony.Prompt do
  @moduledoc "A recording in a tenant's prompt library (`QPBX.Telephony.Prompts`)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "prompts" do
    field :tenant_id, :binary_id
    field :name, :string
    field :file_key, :string, redact: true
    field :format, :string
    field :size, :integer
    timestamps(type: :utc_datetime)
  end

  def changeset(prompt, attrs) do
    prompt
    |> cast(attrs, [:name, :file_key, :format, :size])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :file_key, :format, :size])
    |> validate_length(:name, max: 80)
    |> unique_constraint(:name, name: :prompts_tenant_id_name_index)
  end
end
