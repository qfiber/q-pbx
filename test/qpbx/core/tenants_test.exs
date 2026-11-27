defmodule QPBX.Core.TenantsTest do
  use QPBX.DataCase, async: true
  import QPBX.Fixtures
  alias QPBX.Core

  describe "plans" do
    test "creates a plan with limits and features" do
      assert {:ok, plan} =
               Core.create_plan(%{
                 name: "Basic",
                 max_extensions: 20,
                 allowed_destination_classes: ["local", "mobile"],
                 features: %{"fax" => true}
               })

      assert plan.max_extensions == 20
      assert plan.max_queues == nil
    end

    test "rejects unknown destination classes, features and negative limits" do
      {:error, cs} =
        Core.create_plan(%{
          name: "Bad",
          max_extensions: -1,
          allowed_destination_classes: ["mars"],
          features: %{"teleport" => true}
        })

      assert %{max_extensions: [_], allowed_destination_classes: [_], features: [_]} =
               errors_on(cs)
    end

    test "plan names are unique" do
      plan_fixture(name: "Same")
      assert {:error, cs} = Core.create_plan(%{name: "Same"})
      assert "has already been taken" in errors_on(cs).name
    end
  end

  describe "tenants" do
    test "gets a SIP domain under the base domain" do
      tenant = tenant_fixture(slug: "acme")
      assert tenant.sip_domain == "acme.#{Core.sip_base_domain()}"
    end

    test "slug must be one DNS label and unique" do
      plan = plan_fixture()

      for bad <- ["Acme", "-acme", "acme-", "a.b", "a_b", String.duplicate("a", 64)] do
        assert {:error, cs} =
                 Core.create_tenant(%{
                   name: "x",
                   slug: bad,
                   timezone: "UTC",
                   locale: "en",
                   plan_id: plan.id
                 })

        assert errors_on(cs)[:slug], "expected #{inspect(bad)} to be rejected"
      end

      tenant_fixture(slug: "dup")

      assert {:error, cs} =
               Core.create_tenant(%{
                 name: "x",
                 slug: "dup",
                 timezone: "UTC",
                 locale: "en",
                 plan_id: plan.id
               })

      assert errors_on(cs)[:slug]
    end

    test "validates time zone and locale" do
      assert {:error, cs} =
               Core.create_tenant(%{
                 name: "x",
                 slug: "tz",
                 timezone: "Mars/Base",
                 locale: "fr",
                 plan_id: plan_fixture().id
               })

      assert %{timezone: [_], locale: [_]} = errors_on(cs)
    end

    test "requires an existing plan" do
      assert {:error, cs} =
               Core.create_tenant(%{
                 name: "x",
                 slug: "np",
                 timezone: "UTC",
                 locale: "en",
                 plan_id: Ecto.UUID.generate()
               })

      assert errors_on(cs)[:plan_id]
    end
  end

  describe "effective_limits/1" do
    test "overrides win over the plan, including nil for unlimited" do
      plan = plan_fixture(max_extensions: 10, max_ivrs: 2, max_queues: 1)

      tenant =
        tenant_fixture(
          plan_id: plan.id,
          limit_overrides: %{"max_extensions" => 50, "max_queues" => nil}
        )

      limits = Core.effective_limits(tenant)
      assert limits.max_extensions == 50
      assert limits.max_queues == nil
      assert limits.max_ivrs == 2
    end

    test "rejects unknown or invalid overrides" do
      plan = plan_fixture()

      for bad <- [%{"bogus" => 1}, %{"max_ivrs" => -3}, %{"max_ivrs" => "5"}] do
        assert {:error, cs} =
                 Core.create_tenant(%{
                   name: "x",
                   slug: "o#{unique()}",
                   timezone: "UTC",
                   locale: "en",
                   plan_id: plan.id,
                   limit_overrides: bad
                 })

        assert errors_on(cs)[:limit_overrides]
      end
    end
  end
end
