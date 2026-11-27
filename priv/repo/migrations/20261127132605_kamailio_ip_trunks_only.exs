defmodule QPBX.Repo.Migrations.KamailioIpTrunksOnly do
  use Ecto.Migration

  # Registration trunks leave the dispatcher: they are identified by the R-URI user Kamailio
  # registered as, and a host shared with an IP trunk made the source match ambiguous. Their
  # outbound calls go to their registrar (first address), carried in the trunks htable.
  def up do
    execute """
    CREATE OR REPLACE VIEW kamailio.dispatcher AS
      SELECT row_number() OVER (ORDER BY a.inserted_at, a.id)::integer AS id,
             t.edge_id AS setid,
             #{uri("a")} AS destination,
             0 AS flags,
             100 - a.priority AS priority,
             'weight=' || a.weight || ';trunk=' || t.id || coalesce(';tenant=' || t.tenant_id, '')
               || ';edge=' || t.edge_id AS attrs,
             t.name AS description
        FROM public.trunk_addresses a JOIN public.trunks t ON t.id = a.trunk_id
       WHERE t.enabled AND t.auth_mode = 'ip'
    """

    # edge id -> "<trunk id>;<tenant id or empty>;<auth mode>;<registrar URI or empty>"
    execute """
    CREATE OR REPLACE VIEW kamailio.trunks AS
      SELECT t.edge_id::text AS key_name, 0 AS key_type, 0 AS value_type,
             t.id || ';' || coalesce(t.tenant_id::text, '') || ';' || t.auth_mode || ';'
               || CASE t.auth_mode WHEN 'registration' THEN coalesce(
                    (SELECT #{uri("a")} FROM public.trunk_addresses a WHERE a.trunk_id = t.id
                      ORDER BY a.priority, a.inserted_at LIMIT 1), '') ELSE '' END AS key_value,
             0 AS expires
        FROM public.trunks t
       WHERE t.enabled
      UNION ALL
      SELECT 'reg:' || t.id, 0, 0, t.edge_id::text, 0
        FROM public.trunks t
       WHERE t.enabled AND t.auth_mode = 'registration'
    """
  end

  def down, do: :ok

  defp uri(a) do
    "'sip:' || CASE WHEN #{a}.host LIKE '%:%' THEN '[' || #{a}.host || ']' ELSE #{a}.host END || ':' || #{a}.port " <>
      "|| CASE #{a}.transport WHEN 'udp' THEN '' ELSE ';transport=' || #{a}.transport END"
  end
end
