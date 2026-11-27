defmodule QPBX.Repo.Migrations.KamailioDispatcherAttrs do
  use Ecto.Migration

  # Kamailio cannot parse an attribute with an empty value ("tenant=;"): platform trunks
  # (no tenant) leave the attribute out.
  def up do
    execute """
    CREATE OR REPLACE VIEW kamailio.dispatcher AS
      SELECT row_number() OVER (ORDER BY a.inserted_at, a.id)::integer AS id,
             t.edge_id AS setid,
             'sip:' || CASE WHEN a.host LIKE '%:%' THEN '[' || a.host || ']' ELSE a.host END
               || ':' || a.port
               || CASE a.transport WHEN 'udp' THEN '' ELSE ';transport=' || a.transport END AS destination,
             0 AS flags,
             100 - a.priority AS priority,
             'weight=' || a.weight || ';trunk=' || t.id || coalesce(';tenant=' || t.tenant_id, '')
               || ';edge=' || t.edge_id AS attrs,
             t.name AS description
        FROM public.trunk_addresses a JOIN public.trunks t ON t.id = a.trunk_id
       WHERE t.enabled
    """
  end

  def down, do: :ok
end
