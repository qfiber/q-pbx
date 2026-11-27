defmodule QPBX.Repo.Migrations.CreateLoginFailures do
  use Ecto.Migration

  # Failed login attempts per client IP ("ip:<address>", can be blocked) and per account
  # ("account:<type>:<id>", counted for alerts only; accounts are never locked).
  def change do
    create table(:login_failures, primary_key: false) do
      add :key, :string, primary_key: true
      add :failures, :integer, null: false, default: 0
      add :strikes, :integer, null: false, default: 0
      add :blocked_until, :utc_datetime
      add :last_failure_at, :utc_datetime, null: false
    end

    create index(:login_failures, [:last_failure_at])
  end
end
