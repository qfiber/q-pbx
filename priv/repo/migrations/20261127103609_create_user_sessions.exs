defmodule QPBX.Repo.Migrations.CreateUserSessions do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    create table(:user_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # SHA-256 of the cookie token; the token itself is never stored.
      add :token_hash, :binary, null: false
      add :account_type, :string, null: false
      add :account_id, :binary_id, null: false
      # NULL for platform admins.
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :ip, :string
      add :user_agent, :string
      add :last_seen_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_sessions, [:token_hash])
    create index(:user_sessions, [:account_type, :account_id])
    create index(:user_sessions, [:last_seen_at])
    RLS.enable("user_sessions")
  end
end
