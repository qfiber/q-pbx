defmodule QPBX.Repo.Migrations.CreateAccounts do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:platform_admins, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :name, :string, null: false
      add :hashed_password, :string
      add :locale, :string, null: false, default: "en"
      add :totp_secret, :binary
      add :totp_last_used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:platform_admins, [:email])

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :email, :citext, null: false
      add :name, :string, null: false
      add :hashed_password, :string
      add :locale, :string
      add :totp_secret, :binary
      add :totp_last_used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    # One login per email across tenants: each user belongs to exactly one tenant.
    create unique_index(:users, [:email])
    create index(:users, [:tenant_id])

    create table(:user_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_roles, [:user_id])
    create index(:user_roles, [:tenant_id])

    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # NULL for platform-level actions.
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nilify_all)
      add :actor_type, :string, null: false
      add :actor_id, :binary_id
      add :action, :string, null: false
      add :target_type, :string
      add :target_id, :binary_id
      add :changes, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_logs, [:tenant_id, :inserted_at])
    create index(:audit_logs, [:target_type, :target_id])

    for table <- ~w(users user_roles audit_logs), do: RLS.enable(table)
  end
end
