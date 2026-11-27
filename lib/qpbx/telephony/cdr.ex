defmodule QPBX.Telephony.Cdr do
  @moduledoc "One call leg (`cdrs`): who, where, when, how long and how it ended."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "cdrs" do
    field :tenant_id, :binary_id
    field :leg_uuid, Ecto.UUID
    field :call_uuid, Ecto.UUID
    field :leg, :string
    field :direction, :string
    field :caller_number, :string
    field :caller_name, :string
    field :destination, :string
    field :trunk_id, :binary_id
    field :started_at, :utc_datetime
    field :answered_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :duration, :integer
    field :billsec, :integer
    field :hangup_cause, :string
    field :disposition, :string
    field :recording_key, :string
    field :inserted_at, :utc_datetime, read_after_writes: true
  end
end
