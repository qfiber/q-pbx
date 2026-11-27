defmodule QPBX.Repo.Migrations.Cdrs do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    # One row per call leg, imported from FreeSWITCH's JSON spool (QPBX.Telephony.CdrImporter).
    # A leg with no known tenant (a refused scanner call) keeps tenant_id NULL.
    create table(:cdrs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :leg_uuid, :uuid, null: false
      add :call_uuid, :uuid, null: false
      add :leg, :string, null: false
      add :direction, :string, null: false
      add :caller_number, :string
      add :caller_name, :string
      add :destination, :string
      add :trunk_id, :binary_id
      add :started_at, :utc_datetime, null: false
      add :answered_at, :utc_datetime
      add :ended_at, :utc_datetime, null: false
      add :duration, :integer, null: false
      add :billsec, :integer, null: false
      add :hangup_cause, :string
      add :disposition, :string, null: false
      add :recording_key, :string
      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:cdrs, [:leg_uuid])
    create index(:cdrs, [:tenant_id, :started_at])
    create index(:cdrs, [:call_uuid])
    RLS.enable("cdrs")

    # Calls and talk seconds per tenant, day (tenant's time zone) and direction, from a-legs.
    create table(:usage_daily, primary_key: false) do
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :day, :date, null: false, primary_key: true
      add :direction, :string, null: false, primary_key: true
      add :calls, :integer, null: false, default: 0
      add :answered, :integer, null: false, default: 0
      add :seconds, :integer, null: false, default: 0
    end

    RLS.enable("usage_daily")
  end
end
