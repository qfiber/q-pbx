defmodule QPBX.Fixtures do
  @moduledoc "Test data builders that go through the public APIs."
  use Boundary, top_level?: true, check: [in: false, out: false]

  @actor {:system, "test"}

  def unique, do: System.unique_integer([:positive])

  def plan_fixture(attrs \\ %{}) do
    {:ok, plan} =
      QPBX.Core.create_plan(
        Enum.into(attrs, %{name: "plan-#{unique()}", max_extensions: 10}),
        @actor
      )

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
    {:ok, tenant} = QPBX.Core.create_tenant(attrs, @actor)
    tenant
  end

  def password, do: "correct horse battery"

  def platform_admin_fixture(attrs \\ %{}) do
    {:ok, admin} =
      QPBX.Core.create_platform_admin(
        Enum.into(attrs, %{email: "admin#{unique()}@example.com", name: "Admin"}),
        @actor
      )

    with_password(admin)
  end

  def user_fixture(tenant \\ tenant_fixture(), role \\ "tenant_admin", attrs \\ %{}) do
    {:ok, user} =
      QPBX.Core.create_user(
        tenant,
        Enum.into(attrs, %{email: "user#{unique()}@example.com", name: "User"}),
        role,
        @actor
      )

    with_password(user)
  end

  defp with_password(account) do
    {:ok, account} =
      QPBX.Core.complete_setup(account, %{password: password(), password_confirmation: password()})

    account
  end

  @doc "A valid TOTP code for `secret` in the given 30 s window offset."
  def totp_code(secret, offset \\ 0),
    do: NimbleTOTP.verification_code(secret, time: System.os_time(:second) + offset * 30)
end
