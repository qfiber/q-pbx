defmodule QPBX.Web.Api.AdminController do
  @moduledoc "Platform admins (platform keys with the admin scope)."
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Core.PlatformAdmin

  @admin Schemas.of(PlatformAdmin, "PlatformAdmin")

  def operation(:index),
    do:
      op("Platform admins", "List platform admins", "admin", :platform,
        params: Page.params(),
        response: {:list, @admin}
      )

  def operation(:create),
    do:
      op("Platform admins", "Add a platform admin (emailed a setup link)", "admin", :platform,
        body: %{
          type: "object",
          required: ["name", "email"],
          properties: %{name: %{type: "string"}, email: %{type: "string"}}
        },
        status: 201,
        response: @admin
      )

  def operation(:setup_link),
    do: op("Platform admins", "Email a new setup link", "admin", :platform, response: nil)

  def operation(:sign_out),
    do:
      op("Platform admins", "End every session of a platform admin", "admin", :platform,
        response: nil
      )

  def index(conn, params), do: paged(conn, Core.list_platform_admins(), params)

  def create(conn, params) do
    with {:ok, admin} <-
           Core.create_platform_admin(Map.take(params, ~w(name email)), conn.assigns.api_key) do
      send_link(conn, admin)
      data(conn, admin, 201)
    end
  end

  def setup_link(conn, %{"id" => id}), do: with_admin(id, &reply(conn, send_link(conn, &1), 204))

  def sign_out(conn, %{"id" => id}),
    do: with_admin(id, &reply(conn, Core.revoke_sessions(&1, conn.assigns.api_key), 204))

  defp with_admin(id, fun) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> if a = Core.get_platform_admin(id), do: fun.(a), else: {:error, :not_found}
      :error -> {:error, :not_found}
    end
  end

  # Emailed only: returning it would hand the account to whoever holds the key.
  defp send_link(conn, account) do
    {:ok, token} = Core.issue_setup_link(account, conn.assigns.api_key)
    {:ok, QPBX.Web.send_setup_link(account, token)}
  end
end
