defmodule QPBX.Core do
  @moduledoc """
  Public API of the core area: tenants, plans, limits, users, roles and the audit log.
  See `lib/qpbx/core/CLAUDE.md`.
  """
  use Boundary, deps: [QPBX.Repo], exports: [Plan, Tenant]

  import Ecto.Query
  alias QPBX.Core.{Plan, Tenant}
  alias QPBX.Repo

  ## Plans

  def list_plans, do: Repo.all(from p in Plan, order_by: p.name)
  def get_plan!(id), do: Repo.get!(Plan, id)
  def change_plan(%Plan{} = plan \\ %Plan{}, attrs \\ %{}), do: Plan.changeset(plan, attrs)
  def create_plan(attrs), do: %Plan{} |> Plan.changeset(attrs) |> Repo.insert()
  def update_plan(%Plan{} = plan, attrs), do: plan |> Plan.changeset(attrs) |> Repo.update()

  ## Tenants

  def list_tenants, do: Repo.all(from t in Tenant, order_by: t.name, preload: :plan)
  def get_tenant!(id), do: Tenant |> Repo.get!(id) |> Repo.preload(:plan)

  def change_tenant(%Tenant{} = tenant \\ %Tenant{}, attrs \\ %{}),
    do: Tenant.changeset(tenant, attrs, sip_base_domain())

  def create_tenant(attrs),
    do: %Tenant{} |> Tenant.changeset(attrs, sip_base_domain()) |> Repo.insert()

  def update_tenant(%Tenant{} = tenant, attrs),
    do: tenant |> Tenant.changeset(attrs, sip_base_domain()) |> Repo.update()

  @doc """
  The limits in force for a tenant: the plan's limits with the tenant's overrides on top.
  Returns a map of limit name (atom) to integer, or nil for unlimited.
  """
  def effective_limits(%Tenant{} = tenant) do
    tenant = Repo.preload(tenant, :plan)
    overrides = Map.new(tenant.limit_overrides, fn {k, v} -> {to_limit(k), v} end)
    tenant.plan |> Map.take(Plan.limits()) |> Map.merge(overrides)
  end

  defp to_limit(k) when is_atom(k), do: k
  defp to_limit(k), do: Enum.find(Plan.limits(), &(Atom.to_string(&1) == k))

  def sip_base_domain, do: Application.fetch_env!(:qpbx, :sip_base_domain)
end
