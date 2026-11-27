defmodule QPBX.Repo.Migrations.TelephonyAdmission do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    # Outbound talk time per tenant, destination class and hour (call admission's minute caps;
    # days and months are sums of hours).
    create table(:call_usage, primary_key: false) do
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :class, :string, null: false, primary_key: true
      add :hour, :utc_datetime, null: false, primary_key: true
      add :seconds, :integer, null: false, default: 0
    end

    RLS.enable("call_usage")

    # Velocity rules (fraud): one row, edited by platform admins.
    create table(:fraud_settings, primary_key: false) do
      add :id, :boolean, primary_key: true, default: true
      # International call attempts by one tenant within 10 minutes that count as a spike.
      add :international_spike_calls, :integer, null: false, default: 20
      add :block_on_spike, :boolean, null: false, default: true
      # Quiet hours in the tenant's time zone: international calls then raise an alert.
      add :quiet_start_hour, :integer, null: false, default: 22
      add :quiet_end_hour, :integer, null: false, default: 6
      add :block_in_quiet_hours, :boolean, null: false, default: false
      add :block_hours, :integer, null: false, default: 24
      timestamps(type: :utc_datetime)
    end

    create constraint(:fraud_settings, :one_row, check: "id")

    execute "INSERT INTO fraud_settings (id, inserted_at, updated_at) VALUES (true, now(), now())",
            ""

    # A tenant's international calling blocked by a velocity rule until it expires or is lifted.
    create table(:fraud_blocks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :reason, :string, null: false
      add :until, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:fraud_blocks, [:tenant_id, :until])
    RLS.enable("fraud_blocks")
  end
end
