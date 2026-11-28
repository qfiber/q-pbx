defmodule QPBX.Repo.Migrations.Webhooks do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    create table(:webhook_endpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :url, :string, size: 2000, null: false
      add :description, :string
      add :event_types, {:array, :string}, null: false
      # Encrypted (Cloak): it signs every delivery, so it must be readable; shown once.
      add :secret, :binary, null: false
      add :enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create index(:webhook_endpoints, [:tenant_id])
    RLS.enable("webhook_endpoints")

    # One event sent to one endpoint, with every attempt (the delivery log).
    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :endpoint_id, references(:webhook_endpoints, type: :binary_id, on_delete: :delete_all),
        null: false

      add :event_id, :binary_id, null: false
      add :event_type, :string, null: false
      add :payload, :text, null: false
      # pending (waiting for an attempt), delivered, dead (gave up after 24 hours)
      add :status, :string, null: false, default: "pending"
      add :attempts, {:array, :map}, null: false, default: []
      add :delivered_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:webhook_deliveries, [:endpoint_id, :inserted_at])
    create index(:webhook_deliveries, [:inserted_at])
    RLS.enable("webhook_deliveries")
  end
end
