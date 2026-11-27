defmodule QPBX.Telephony.Voicemail.Message do
  @moduledoc "A voicemail message: audio in storage (`file_key`), folder new or saved."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "voicemails" do
    field :tenant_id, :binary_id
    field :mailbox_id, :binary_id
    field :caller_number, :string
    field :caller_name, :string
    field :duration, :integer
    field :file_key, :string
    field :format, :string
    field :folder, :string, default: "new"
    timestamps(type: :utc_datetime)
  end
end
