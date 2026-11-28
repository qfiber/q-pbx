defmodule QPBX.Web.Api.UserController do
  @moduledoc "The tenant's users (tenant keys with the admin scope), as on the Users page."
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Core.User

  @user Schemas.of(User, "User")

  def operation(:index),
    do:
      op("Users", "List users", "admin", :tenant, params: Page.params(), response: {:list, @user})

  def operation(:create),
    do:
      op("Users", "Invite a user (emailed a setup link)", "admin", :tenant,
        body: %{
          type: "object",
          required: ["name", "email"],
          properties: %{
            name: %{type: "string"},
            email: %{type: "string"},
            role: %{type: "string", enum: ["tenant_admin", "tenant_user"], default: "tenant_user"},
            extension_id: %{type: ["string", "null"], format: "uuid"}
          }
        },
        status: 201,
        response: @user
      )

  def operation(:update),
    do:
      op("Users", "Change a user's role or own extension", "admin", :tenant,
        body: %{
          type: "object",
          properties: %{
            role: %{type: "string", enum: ["tenant_admin", "tenant_user"]},
            extension_id: %{type: ["string", "null"], format: "uuid", description: "null: none"}
          }
        },
        response: @user
      )

  def operation(:delete),
    do: op("Users", "Remove a user (their sessions end)", "admin", :tenant, response: nil)

  def operation(:setup_link),
    do: op("Users", "Email a user a new setup link", "admin", :tenant, response: nil)

  def operation(:sign_out),
    do: op("Users", "End every session of a user", "admin", :tenant, response: nil)

  def index(conn, params), do: paged(conn, Core.list_tenant_users(scope(conn)), params)

  def create(conn, params) do
    locale = conn.assigns.api_key.tenant.locale
    attrs = params |> Map.take(~w(name email role extension_id)) |> Map.put("locale", locale)

    with {:ok, user} <- Core.invite_user(scope(conn), attrs, actor(conn)) do
      {:ok, _} = QPBX.Notify.deliver_setup_link(user, QPBX.Web.setup_url(Core.setup_token(user)))
      data(conn, find(conn, user.id), 201)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- maybe(params, "role", &set_role(conn, id, &1)),
         :ok <-
           maybe(
             params,
             "extension_id",
             &Core.set_user_extension(scope(conn), id, &1, actor(conn))
           ) do
      if u = find(conn, id), do: data(conn, u), else: {:error, :not_found}
    end
  end

  def delete(conn, %{"id" => id}),
    do: reply(conn, Core.delete_user(scope(conn), id, actor(conn)), 204)

  def setup_link(conn, %{"id" => id}) do
    with {:ok, user, token} <- Core.user_setup_link(scope(conn), id, actor(conn)) do
      QPBX.Web.send_setup_link(user, token)
      send_resp(conn, 204, "")
    end
  end

  def sign_out(conn, %{"id" => id}),
    do: reply(conn, Core.sign_out_user(scope(conn), id, actor(conn)), 204)

  defp maybe(params, key, fun) do
    case Map.fetch(params, key) do
      :error -> :ok
      {:ok, value} -> with({:ok, _} <- fun.(value), do: :ok)
    end
  end

  defp set_role(conn, id, role) when role in ["tenant_admin", "tenant_user"],
    do: Core.set_user_role(scope(conn), id, role, actor(conn))

  defp set_role(_, _, _), do: {:error, :unknown_role}

  defp find(conn, id), do: Enum.find(Core.list_tenant_users(scope(conn)), &(&1.id == id))
  defp scope(conn), do: conn.assigns.current_scope
  defp actor(conn), do: conn.assigns.api_key
end
