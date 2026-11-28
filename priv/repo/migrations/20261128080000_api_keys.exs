defmodule QPBX.Repo.Migrations.ApiKeys do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # NULL for platform keys.
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :name, :string, null: false
      # The key's first characters, to tell keys apart; the key itself is never stored.
      add :prefix, :string, null: false
      add :token_hash, :binary, null: false
      add :scopes, {:array, :string}, null: false
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:api_keys, [:token_hash])
    create index(:api_keys, [:tenant_id])
    RLS.enable("api_keys")

    # POST replays: the first response to each Idempotency-Key, kept 24 hours.
    create table(:api_idempotency, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)

      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key, :string, null: false
      add :fingerprint, :binary, null: false
      # NULL while the first request is still running.
      add :status, :integer
      add :body, :text
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:api_idempotency, [:api_key_id, :key])
    RLS.enable("api_idempotency")
  end
end
