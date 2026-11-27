defmodule QPBX.Repo.Migrations.EdgeSettingsAndBans do
  use Ecto.Migration

  def change do
    # Edge protection settings: one row, edited by platform admins, read by Kamailio at run time.
    create table(:edge_settings, primary_key: false) do
      add :id, :boolean, primary_key: true, default: true
      add :flood_requests, :integer, null: false, default: 40
      add :register_per_minute, :integer, null: false, default: 30
      add :invite_per_minute, :integer, null: false, default: 30
      add :auth_failures_port, :integer, null: false, default: 10
      add :auth_failures_ip, :integer, null: false, default: 30
      add :ban_seconds, :integer, null: false, default: 3600

      add :scanner_agents, :text,
        null: false,
        default:
          "friendly-scanner|sipvicious|sipcli|sip-scan|sundayddr|iWar|VaxSIPUserAgent|pplsip|SIPScan|smap"

      timestamps(type: :utc_datetime)
    end

    create constraint(:edge_settings, :one_row, check: "id")

    execute "INSERT INTO edge_settings (id, inserted_at, updated_at) VALUES (true, now(), now())",
            ""

    # Every ban Kamailio placed (whole address "<ip>" or one phone "<ip>|<port>"), kept so a
    # restarted Kamailio loads them back.
    create table(:edge_bans, primary_key: false) do
      add :key, :string, primary_key: true
      add :ip, :string, null: false
      add :port, :integer
      add :reason, :string, null: false
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:edge_bans, [:expires_at])

    # htable "settings": name -> value (value_type 1 = integer, 0 = string).
    execute(
      """
      CREATE VIEW kamailio.settings AS
        SELECT k AS key_name, 0 AS key_type, t AS value_type, v AS key_value, 0 AS expires
          FROM public.edge_settings s,
               LATERAL (VALUES
                 ('flood_requests', 1, s.flood_requests::text),
                 ('register_per_minute', 1, s.register_per_minute::text),
                 ('invite_per_minute', 1, s.invite_per_minute::text),
                 ('auth_failures_port', 1, s.auth_failures_port::text),
                 ('auth_failures_ip', 1, s.auth_failures_ip::text),
                 ('ban_seconds', 1, s.ban_seconds::text),
                 ('scanner_agents', 0, s.scanner_agents)) AS x(k, t, v)
      """,
      "DROP VIEW kamailio.settings"
    )

    # htable "ipban", loaded at Kamailio start: active bans with their expiry (unix time).
    execute(
      """
      CREATE VIEW kamailio.ipban AS
        SELECT b.key AS key_name, 0 AS key_type, 0 AS value_type, b.reason AS key_value,
               extract(epoch FROM b.expires_at)::integer AS expires
          FROM public.edge_bans b
         WHERE b.expires_at > now()
      """,
      "DROP VIEW kamailio.ipban"
    )

    if role = System.get_env("QPBX_DB_KAMAILIO_ROLE") do
      true = Regex.match?(~r/\A[a-z_][a-z0-9_]{0,62}\z/, role)
      execute "GRANT SELECT ON kamailio.settings, kamailio.ipban TO #{role}", "SELECT 1"
    end
  end
end
