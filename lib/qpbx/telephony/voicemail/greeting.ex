defmodule QPBX.Telephony.Voicemail.Greeting do
  @moduledoc "A mailbox greeting: unavailable, busy or temporary (wins while it exists)."
  use Ecto.Schema

  @kinds ~w(unavailable busy temporary)
  def kinds, do: @kinds

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "greetings" do
    field :tenant_id, :binary_id
    field :mailbox_id, :binary_id
    field :kind, :string
    field :file_key, :string
    field :format, :string
    timestamps(type: :utc_datetime)
  end
end
