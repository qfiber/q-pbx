defmodule QPBX.Repo.Migrations.KamailioAddressView do
  use Ecto.Migration

  # Firewall area: SIP allow entries for Kamailio's permissions module. Group 1: platform
  # (management IPs, carriers, monitoring); group 2: tenant office IPs (tag = tenant id).
  # Blocks are dropped by nftables before Kamailio sees them. Expired entries leave the view
  # on their own; the app reloads it every minute.
  def change do
    execute(
      """
      CREATE VIEW kamailio.address AS
        SELECT row_number() OVER (ORDER BY e.inserted_at, e.id)::integer AS id,
               CASE e.level WHEN 'platform' THEN 1 ELSE 2 END AS grp,
               split_part(e.cidr, '/', 1) AS ip_addr,
               coalesce(nullif(split_part(e.cidr, '/', 2), '')::integer,
                        CASE e.family WHEN 'v6' THEN 128 ELSE 32 END) AS mask,
               0 AS port,
               coalesce(e.tenant_id::text, '') AS tag
          FROM public.firewall_entries e
         WHERE e.kind = 'allow' AND e.scope IN ('sip', 'all')
           AND (e.expires_at IS NULL OR e.expires_at > now())
      """,
      "DROP VIEW kamailio.address"
    )

    if role = System.get_env("QPBX_DB_KAMAILIO_ROLE") do
      true = Regex.match?(~r/\A[a-z_][a-z0-9_]{0,62}\z/, role)
      execute "GRANT SELECT ON kamailio.address TO #{role}", "SELECT 1"
    end
  end
end
