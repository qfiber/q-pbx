defmodule QPBX.Core.Numbering do
  @moduledoc """
  Number formats (the platform default and tenant overrides), the platform's destination
  class prefixes (including the high-cost list) and emergency routes.
  """
  import Ecto.Query
  alias QPBX.Core.{Changes, EmergencyRoute, NumberClass, NumberRule, Scope, Trunk}
  alias QPBX.Repo

  ## Number rules

  @doc "The rule in force: the tenant's override, else the platform default, else Israel's."
  def rule(%Scope{kind: :tenant, tenant_id: tid} = scope) do
    Scope.run(scope, fn -> Repo.one(from r in NumberRule, where: r.tenant_id == ^tid) end) ||
      platform_rule()
  end

  def rule(%Scope{kind: :platform}), do: platform_rule()

  defp platform_rule,
    do: Repo.one(from r in NumberRule, where: is_nil(r.tenant_id)) || NumberRule.israel_default()

  def change_rule(%NumberRule{} = rule, attrs \\ %{}), do: NumberRule.changeset(rule, attrs)

  @doc "Saves the scope's own rule (a tenant override, or the platform default)."
  def put_rule(%Scope{} = scope, attrs, actor) do
    tid = scope.tenant_id

    Scope.run(scope, fn ->
      case Repo.one(from r in NumberRule, where: ^dynamic_tenant(tid)) do
        nil ->
          %NumberRule{tenant_id: tid}
          |> NumberRule.changeset(attrs)
          |> Changes.insert(actor, "number_rule.create")

        rule ->
          rule |> NumberRule.changeset(attrs) |> Changes.update(actor, "number_rule.update")
      end
    end)
    |> Changes.announce(tid, "number_rules")
  end

  @doc "A tenant goes back to the platform default."
  def reset_rule(%Scope{kind: :tenant, tenant_id: tid} = scope, actor) do
    Scope.run(scope, fn ->
      case Repo.one(from r in NumberRule, where: r.tenant_id == ^tid) do
        nil -> {:ok, nil}
        rule -> Changes.delete(rule, actor, "number_rule.delete")
      end
    end)
    |> Changes.announce(tid, "number_rules")
  end

  defp dynamic_tenant(nil), do: dynamic([r], is_nil(r.tenant_id))
  defp dynamic_tenant(tid), do: dynamic([r], r.tenant_id == ^tid)

  ## Destination class prefixes (platform)

  def list_classes, do: Repo.all(from c in NumberClass, order_by: c.prefix)
  def change_class(attrs \\ %{}), do: NumberClass.changeset(%NumberClass{}, attrs)

  def create_class(%Scope{kind: :platform} = scope, attrs, actor) do
    Scope.run(scope, fn ->
      %NumberClass{}
      |> NumberClass.changeset(attrs)
      |> Changes.insert(actor, "number_class.create")
    end)
    |> Changes.announce(nil, "number_classes")
  end

  def delete_class(%Scope{kind: :platform} = scope, id, actor) do
    Scope.run(scope, fn ->
      Changes.delete(Repo.get!(NumberClass, id), actor, "number_class.delete")
    end)
    |> Changes.announce(nil, "number_classes")
  end

  ## Emergency routes (platform)

  def list_emergency, do: Repo.all(from e in EmergencyRoute, order_by: e.number)
  def change_emergency(attrs \\ %{}), do: EmergencyRoute.changeset(%EmergencyRoute{}, attrs)

  def create_emergency(%Scope{kind: :platform} = scope, attrs, actor) do
    Scope.run(scope, fn ->
      cs = EmergencyRoute.changeset(%EmergencyRoute{}, attrs)
      trunk_id = Ecto.Changeset.get_field(cs, :trunk_id)

      platform? =
        trunk_id &&
          Repo.exists?(from t in Trunk, where: t.id == ^trunk_id and is_nil(t.tenant_id))

      cs =
        if platform?,
          do: cs,
          else: Ecto.Changeset.add_error(cs, :trunk_id, "must be a platform trunk")

      Changes.insert(cs, actor, "emergency_route.create")
    end)
    |> Changes.announce(nil, "emergency_routes")
  end

  def delete_emergency(%Scope{kind: :platform} = scope, id, actor) do
    Scope.run(scope, fn ->
      Changes.delete(Repo.get!(EmergencyRoute, id), actor, "emergency_route.delete")
    end)
    |> Changes.announce(nil, "emergency_routes")
  end
end
