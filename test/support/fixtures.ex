defmodule QPBX.Fixtures do
  @moduledoc "Test data builders that go through the public APIs."
  use Boundary, top_level?: true, check: [in: false, out: false]

  def unique, do: System.unique_integer([:positive])

  def plan_fixture(attrs \\ %{}) do
    {:ok, plan} =
      QPBX.Core.create_plan(Enum.into(attrs, %{name: "plan-#{unique()}", max_extensions: 10}))

    plan
  end

  def tenant_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Acme",
        slug: "t#{unique()}",
        timezone: "Asia/Jerusalem",
        locale: "en"
      })

    attrs = Map.put_new_lazy(attrs, :plan_id, fn -> plan_fixture().id end)
    {:ok, tenant} = QPBX.Core.create_tenant(attrs)
    tenant
  end
end
