defmodule QPBX.Web.Api.TenantController do
  @moduledoc "Tenants and their users (platform keys), as on the platform's tenant pages."
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Core.{Tenant, User}
  alias QPBX.Web.Api.Error

  @tenant Schemas.of(Tenant, "Tenant")
  @user Schemas.of(User, "User")
  @admin %{
    type: "object",
    required: ["name", "email"],
    properties: %{name: %{type: "string"}, email: %{type: "string"}}
  }

  def operation(:index),
    do:
      op("Tenants", "List tenants", "read", :platform,
        params: Page.params(),
        response: {:list, @tenant}
      )

  def operation(:show), do: op("Tenants", "Get a tenant", "read", :platform, response: @tenant)

  def operation(:create),
    do:
      op(
        "Tenants",
        "Create a tenant with its first tenant admin (emailed a setup link)",
        "write",
        :platform,
        body:
          Schemas.input(Tenant, "TenantInput", ~w(name slug timezone locale plan_id admin), %{
            admin: @admin
          }),
        status: 201,
        response: @tenant
      )

  def operation(:update),
    do:
      op(
        "Tenants",
        "Change a tenant (name, plan, time zone, language, limit overrides)",
        "write",
        :platform,
        body: Schemas.input(Tenant, "TenantChange"),
        response: @tenant
      )

  def operation(:users),
    do:
      op("Tenants", "A tenant's users", "admin", :platform,
        params: Page.params(),
        response: {:list, @user}
      )

  def operation(:add_admin),
    do:
      op("Tenants", "Add a tenant admin (emailed a setup link)", "admin", :platform,
        body: @admin,
        status: 201,
        response: @user
      )

  def operation(:setup_link),
    do: op("Tenants", "Email a tenant user a new setup link", "admin", :platform, response: nil)

  def operation(:sign_out),
    do: op("Tenants", "End every session of a tenant user", "admin", :platform, response: nil)

  def index(conn, params), do: paged(conn, Core.list_tenants(), params)
  def show(conn, %{"id" => id}), do: data(conn, Core.get_tenant!(id))

  def create(conn, params) do
    admin =
      Map.merge(Map.take(params["admin"] || %{}, ~w(name email)), %{"locale" => params["locale"]})

    attrs = Map.take(params, ~w(name slug timezone locale plan_id))

    case Core.create_tenant_with_admin(attrs, admin, conn.assigns.api_key) do
      {:ok, %{tenant: tenant, admin: user}} ->
        {:ok, _job} =
          QPBX.Notify.deliver_setup_link(user, QPBX.Web.setup_url(Core.setup_token(user)))

        data(conn, tenant, 201)

      # The admin's field errors under "admin", as the request nests them.
      {:error, :admin, cs} ->
        Error.send(conn, 422, "invalid", "The request has invalid fields.", %{
          admin: Error.changeset_details(cs)
        })

      {:error, _, cs} ->
        {:error, cs}
    end
  end

  def update(conn, %{"id" => id} = params),
    do:
      reply(
        conn,
        Core.update_tenant(
          Core.get_tenant!(id),
          Map.drop(params, ["id", "slug"]),
          conn.assigns.api_key
        )
      )

  def users(conn, %{"tenant_id" => id} = params),
    do: paged(conn, Core.list_users(%Core.Scope{kind: :platform}, Core.get_tenant!(id)), params)

  def add_admin(conn, %{"tenant_id" => id} = params) do
    tenant = Core.get_tenant!(id)
    attrs = params |> Map.take(~w(name email)) |> Map.put("locale", tenant.locale)

    with {:ok, user} <- Core.create_user(tenant, attrs, "tenant_admin", conn.assigns.api_key) do
      send_link(conn, user)
      data(conn, Core.get_user(user.id), 201)
    end
  end

  def setup_link(conn, params), do: with_user(conn, params, &send_link(conn, &1))

  def sign_out(conn, params),
    do: with_user(conn, params, &Core.revoke_sessions(&1, conn.assigns.api_key))

  defp with_user(conn, %{"tenant_id" => tid, "id" => id}, fun) do
    case Enum.find(
           Core.list_users(%Core.Scope{kind: :platform}, Core.get_tenant!(tid)),
           &(&1.id == id)
         ) do
      nil -> {:error, :not_found}
      user -> reply(conn, fun.(user), 204)
    end
  end

  # The link goes by email only: returning it would hand the account to whoever holds the key.
  defp send_link(conn, account) do
    {:ok, token} = Core.issue_setup_link(account, conn.assigns.api_key)
    {:ok, QPBX.Web.send_setup_link(account, token)}
  end
end
