defmodule QPBX.Repo.Migrations.KamailioTrunkViews do
  use Ecto.Migration

  def change do
    # Kamailio's dispatcher numbers its sets; each trunk gets a stable integer for it.
    execute(
      "ALTER TABLE trunks ADD COLUMN edge_id integer GENERATED ALWAYS AS IDENTITY UNIQUE",
      "ALTER TABLE trunks DROP COLUMN edge_id"
    )

    # dispatcher: one destination per trunk address; lower Q-PBX priority = tried first
    # (dispatcher orders by priority descending). attrs carry the trunk and tenant.
    execute(
      """
      CREATE VIEW kamailio.dispatcher AS
        SELECT row_number() OVER (ORDER BY a.inserted_at, a.id)::integer AS id,
               t.edge_id AS setid,
               'sip:' || CASE WHEN a.host LIKE '%:%' THEN '[' || a.host || ']' ELSE a.host END
                 || ':' || a.port
                 || CASE a.transport WHEN 'udp' THEN '' ELSE ';transport=' || a.transport END AS destination,
               0 AS flags,
               100 - a.priority AS priority,
               'weight=' || a.weight || ';trunk=' || t.id || ';tenant=' || coalesce(t.tenant_id::text, '')
                 || ';edge=' || t.edge_id AS attrs,
               t.name AS description
          FROM public.trunk_addresses a JOIN public.trunks t ON t.id = a.trunk_id
         WHERE t.enabled
      """,
      "DROP VIEW kamailio.dispatcher"
    )

    # htable "trunks": edge id -> "<trunk id>;<tenant id or empty>;<auth mode>", and for
    # registration trunks "reg:<trunk id>" -> edge id: Kamailio registers as the trunk id (an
    # unguessable UUID), so a carrier's INVITE to that user identifies the trunk.
    execute(
      """
      CREATE VIEW kamailio.trunks AS
        SELECT t.edge_id::text AS key_name, 0 AS key_type, 0 AS value_type,
               t.id || ';' || coalesce(t.tenant_id::text, '') || ';' || t.auth_mode AS key_value,
               0 AS expires
          FROM public.trunks t
         WHERE t.enabled
        UNION ALL
        SELECT 'reg:' || t.id, 0, 0, t.edge_id::text, 0
          FROM public.trunks t
         WHERE t.enabled AND t.auth_mode = 'registration'
      """,
      "DROP VIEW kamailio.trunks"
    )

    # The uac module needs a table to start remote registrations; the records themselves
    # (with the decrypted password) arrive from the app over JSON-RPC, never through the
    # database. So this view is always empty.
    execute(
      """
      CREATE VIEW kamailio.uacreg AS
        SELECT 0 AS id, ''::varchar AS l_uuid, ''::varchar AS l_username, ''::varchar AS l_domain,
               ''::varchar AS r_username, ''::varchar AS r_domain, ''::varchar AS realm,
               ''::varchar AS auth_username, ''::varchar AS auth_password, ''::varchar AS auth_ha1,
               ''::varchar AS auth_proxy, 0 AS expires, 0 AS flags, 0 AS reg_delay,
               ''::varchar AS contact_addr, ''::varchar AS socket
         WHERE false
      """,
      "DROP VIEW kamailio.uacreg"
    )

    # Kamailio's "version" table: modules check their table versions at start-up.
    execute(
      """
      CREATE VIEW kamailio.version AS
        SELECT * FROM (VALUES ('dispatcher', 4), ('uacreg', 4), ('address', 6)) v(table_name, table_version)
      """,
      "DROP VIEW kamailio.version"
    )

    if role = kamailio_role() do
      execute "GRANT SELECT ON ALL TABLES IN SCHEMA kamailio TO #{role}", "SELECT 1"
    end
  end

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
