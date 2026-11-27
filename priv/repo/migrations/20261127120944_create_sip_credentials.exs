defmodule QPBX.Repo.Migrations.CreateSipCredentials do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    # SIP digest credentials. Only HA1 (md5 of user:domain:password) is kept: Kamailio checks
    # digests against it, and the password itself is shown once and never stored.
    create table(:sip_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :username, :string, null: false
      add :ha1, :string, null: false
      add :enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:sip_credentials, [:tenant_id, :username])
    RLS.enable("sip_credentials")

    # Kamailio's read-only window: rows shaped for its htable module (key_name, key_type,
    # value_type, key_value, expires), loaded into memory and reloaded on change.
    execute "CREATE SCHEMA kamailio", "DROP SCHEMA kamailio"

    execute(
      """
      CREATE VIEW kamailio.credentials AS
        SELECT c.username || '@' || t.sip_domain AS key_name, 0 AS key_type, 0 AS value_type,
               c.ha1 AS key_value, 0 AS expires
          FROM public.sip_credentials c JOIN public.tenants t ON t.id = c.tenant_id
         WHERE c.enabled
      """,
      "DROP VIEW kamailio.credentials"
    )

    execute(
      """
      CREATE VIEW kamailio.domains AS
        SELECT t.sip_domain AS key_name, 0 AS key_type, 0 AS value_type,
               t.id::text AS key_value, 0 AS expires
          FROM public.tenants t
      """,
      "DROP VIEW kamailio.domains"
    )

    if role = kamailio_role() do
      execute "GRANT USAGE ON SCHEMA kamailio TO #{role}",
              "REVOKE USAGE ON SCHEMA kamailio FROM #{role}"

      execute "GRANT SELECT ON ALL TABLES IN SCHEMA kamailio TO #{role}", "SELECT 1"
    end
  end

  # Production only (QPBX_DB_KAMAILIO_ROLE); development and tests have no Kamailio role.
  defp kamailio_role do
    case System.get_env("QPBX_DB_KAMAILIO_ROLE") do
      nil ->
        nil

      role ->
        if Regex.match?(~r/\A[a-z_][a-z0-9_]{0,62}\z/, role),
          do: role,
          else: raise("bad QPBX_DB_KAMAILIO_ROLE")
    end
  end
end
