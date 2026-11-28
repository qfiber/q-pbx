defmodule QPBX.Web.Api.ApiKeyController do
  @moduledoc "API keys of the key's own scope (tenant or platform), with the admin scope."
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Core.ApiKey

  @key Schemas.of(ApiKey, "ApiKey")

  def operation(:index),
    do:
      op("API keys", "List API keys", "admin", :any,
        params: Page.params(),
        response: {:list, @key}
      )

  def operation(:create),
    do:
      op(
        "API keys",
        "Create an API key; the response's token is shown only this once",
        "admin",
        :any,
        body: %{
          type: "object",
          required: ["name", "scopes"],
          properties: %{
            name: %{type: "string"},
            scopes: %{type: "array", items: %{type: "string", enum: ApiKey.scopes()}},
            expires_in: %{
              type: "string",
              enum: ["never" | Enum.map(ApiKey.expiry_days(), &to_string/1)],
              default: "90"
            }
          }
        },
        status: 201,
        response: @key
      )

  def operation(:delete),
    do: op("API keys", "Revoke an API key (it stops at once)", "admin", :any, response: nil)

  def index(conn, params), do: paged(conn, Core.list_api_keys(conn.assigns.current_scope), params)

  def create(conn, params) do
    with {:ok, key, token} <-
           Core.create_api_key(conn.assigns.current_scope, params, conn.assigns.api_key) do
      conn |> put_status(201) |> json(%{data: Schemas.render(key), token: token})
    end
  end

  def delete(conn, %{"id" => id}),
    do:
      reply(conn, Core.revoke_api_key(conn.assigns.current_scope, id, conn.assigns.api_key), 204)
end
