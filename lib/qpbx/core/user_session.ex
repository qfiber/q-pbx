defmodule QPBX.Core.UserSession do
  @moduledoc "One signed-in browser. The cookie holds a random token; only its hash is stored."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_sessions" do
    field :token_hash, :binary, redact: true
    field :account_type, :string
    field :account_id, :binary_id
    field :tenant_id, :binary_id
    field :ip, :string
    field :user_agent, :string
    field :last_seen_at, :utc_datetime
    field :expires_at, :utc_datetime
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
