defmodule QPBX.Repo.Migrations.CreatePlansAndTenants do
  use Ecto.Migration

  def change do
    create table(:plans, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      # Limits: NULL means unlimited.
      add :max_extensions, :integer
      add :max_concurrent_calls_inbound, :integer
      add :max_concurrent_calls_outbound, :integer
      add :max_concurrent_calls_total, :integer
      add :max_queues, :integer
      add :max_ivrs, :integer
      add :max_conferences, :integer
      add :recording_storage_gb, :integer
      add :fax_storage_gb, :integer
      add :outbound_minutes_per_day, :integer
      add :outbound_minutes_per_month, :integer
      add :allowed_destination_classes, {:array, :string}, null: false, default: []
      add :api_rate_limit_per_minute, :integer
      add :features, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:plans, [:name])

    create table(:tenants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :sip_domain, :string, null: false
      add :timezone, :string, null: false
      add :locale, :string, null: false
      add :plan_id, references(:plans, type: :binary_id, on_delete: :restrict), null: false
      add :limit_overrides, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:tenants, [:slug])
    create unique_index(:tenants, [:sip_domain])
    create index(:tenants, [:plan_id])
  end
end
