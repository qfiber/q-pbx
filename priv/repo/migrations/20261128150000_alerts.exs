defmodule QPBX.Repo.Migrations.Alerts do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    # One problem: repeats of the same key while it is not resolved are counted on it.
    create table(:alerts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # NULL: a platform alert.
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :key, :string, null: false
      add :kind, :string, null: false
      add :category, :string, null: false
      add :severity, :string, null: false
      add :title, :string, null: false
      add :message, :text, null: false
      add :data, :map, null: false, default: %{}
      # A personal alert's user (missed call, voicemail, login from a new IP).
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :state, :string, null: false, default: "open"
      add :count, :integer, null: false, default: 1
      # Repeats since recipients were last told, and when that was.
      add :repeats, :integer, null: false, default: 0
      add :notified_at, :utc_datetime_usec
      add :acknowledged_at, :utc_datetime
      add :acknowledged_by, :string
      add :resolved_at, :utc_datetime
      timestamps(type: :utc_datetime_usec)
    end

    create index(:alerts, [:tenant_id, :inserted_at])
    # At most one unresolved alert per key: repeats land on it.
    create unique_index(
             :alerts,
             ["coalesce(tenant_id, '00000000-0000-0000-0000-000000000000')", :key],
             where: "state <> 'resolved'",
             name: :alerts_open_key
           )

    RLS.enable("alerts")

    # Categories platform admins made mandatory (people cannot switch them off).
    create table(:alert_rules, primary_key: false) do
      add :category, :string, primary_key: true
      add :mandatory, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    # A person's channels per category and quiet hours (users and platform admins).
    create table(:notification_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :account_type, :string, null: false
      add :account_id, :binary_id, null: false
      add :channels, :map, null: false, default: %{}
      add :quiet_start, :integer
      add :quiet_end, :integer
      # Quiet hours are local hours in this zone (default: the tenant's; UTC for platform admins).
      add :timezone, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:notification_preferences, [:account_type, :account_id])
    RLS.enable("notification_preferences")

    # Shared recipients (an email address) and alert webhooks, of a tenant or the platform.
    create table(:alert_channels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :kind, :string, null: false
      add :address, :string, size: 2000, null: false
      add :categories, {:array, :string}, null: false
      add :min_severity, :string, null: false, default: "info"
      # webhooks: generic JSON or Alertmanager's receiver format
      add :format, :string, null: false, default: "generic"
      add :secret, :binary
      add :enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create index(:alert_channels, [:tenant_id])
    RLS.enable("alert_channels")

    # What one recipient was told about one alert, on one channel, and how it went.
    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :alert_id, references(:alerts, type: :binary_id, on_delete: :delete_all), null: false
      # raised, repeated, acknowledged, resolved, test
      add :event, :string, null: false
      # portal, email, webhook
      add :channel, :string, null: false
      # A person (portal, email) or a shared channel (email, webhook).
      add :account_type, :string
      add :account_id, :binary_id
      add :alert_channel_id, references(:alert_channels, type: :binary_id, on_delete: :delete_all)
      add :address, :string, size: 2000
      # pending, sent, failed (retrying), dead, bounced, skipped (quiet hours or the rate cap)
      add :status, :string, null: false, default: "pending"
      add :reason, :string
      add :attempts, {:array, :map}, null: false, default: []
      add :read_at, :utc_datetime
      # SHA-256 of the acknowledge link's token (emails); the token is only in the email.
      add :ack_token_hash, :binary
      timestamps(type: :utc_datetime_usec)
    end

    create index(:notifications, [:account_type, :account_id, :inserted_at])
    create index(:notifications, [:alert_id])
    create index(:notifications, [:tenant_id, :inserted_at])
    create unique_index(:notifications, [:ack_token_hash])
    RLS.enable("notifications")
  end
end
