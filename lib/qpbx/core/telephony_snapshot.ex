defmodule QPBX.Core.TelephonySnapshot do
  @moduledoc """
  Read-only views of the telephony configuration for call control (`QPBX.Telephony`), which
  caches them in memory and drops them on `ConfigChanged`. Internal: not for tenant-facing
  code (tenant data is still read under the tenant's row-level security).
  """
  import Ecto.Query

  alias QPBX.Core.{
    Did,
    EmergencyRoute,
    Extension,
    NumberClass,
    NumberRule,
    OutboundRoute,
    Scope,
    Tenant,
    Trunk
  }

  alias QPBX.Repo

  @doc "Everything call control needs about one tenant, or nil if it does not exist."
  def tenant(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      nil ->
        nil

      tenant ->
        scope = %Scope{kind: :tenant, tenant_id: tenant_id}

        Scope.run(scope, fn ->
          %{
            tenant: Repo.preload(tenant, :plan),
            limits: QPBX.Core.effective_limits(tenant),
            rule: QPBX.Core.number_rule(scope),
            extensions:
              Repo.all(
                from e in Extension,
                  where: e.tenant_id == ^tenant_id,
                  preload: [devices: :sip_credential]
              ),
            routes:
              Repo.all(
                from r in OutboundRoute,
                  where: r.tenant_id == ^tenant_id,
                  order_by: [r.position, r.name],
                  preload: :route_trunks
              )
              |> Enum.map(&%{&1 | trunk_ids: Enum.map(&1.route_trunks, fn rt -> rt.trunk_id end)}),
            dids: Repo.all(from d in Did, where: d.tenant_id == ^tenant_id)
          }
        end)
    end
  end

  @doc "Platform data: every trunk by id, emergency routes, destination class prefixes."
  def platform do
    %{
      trunks: Map.new(Repo.all(from(t in Trunk)), &{&1.id, &1}),
      emergency: Repo.all(from e in EmergencyRoute, where: e.enabled),
      classes: Repo.all(from c in NumberClass, select: {c.prefix, c.class}),
      default_rule:
        Repo.one(from r in NumberRule, where: is_nil(r.tenant_id)) || NumberRule.israel_default()
    }
  end

  @doc "Every extension as `{id, number, sip_domain}`, optionally of one tenant (voicemail lights)."
  def extension_addresses(tenant_id \\ nil) do
    query =
      from e in Extension,
        join: t in Tenant,
        on: t.id == e.tenant_id,
        select: {e.id, e.number, t.sip_domain}

    query = if tenant_id, do: where(query, [e], e.tenant_id == ^tenant_id), else: query
    Repo.all(query)
  end

  @doc "Every DID by number (E.164), for incoming calls from carriers."
  def dids, do: Map.new(Repo.all(from(d in Did)), &{&1.number, &1})
end
