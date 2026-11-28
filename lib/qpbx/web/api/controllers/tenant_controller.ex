defmodule QPBX.Web.Api.TenantController do
  @moduledoc "Tenants (platform keys only)."
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Web.Api.{Page, Schemas}

  def operation(:index),
    do: %{
      summary: "List tenants",
      tag: "Tenants",
      scope: "read",
      audience: :platform,
      params: Page.params(),
      response: {:list, Schemas.tenant()}
    }

  def index(conn, params) do
    case Page.paginate(Core.list_tenants(), params) do
      {:ok, page, next} ->
        json(conn, %{data: Enum.map(page, &Schemas.render/1), next_cursor: next})

      {:error, message} ->
        {:error, {:bad_request, message}}
    end
  end
end
