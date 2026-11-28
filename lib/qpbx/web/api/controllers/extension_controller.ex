defmodule QPBX.Web.Api.ExtensionController do
  @moduledoc "Extensions of the key's tenant, through the same Core functions the portal uses."
  use QPBX.Web, :api_controller
  alias QPBX.Core
  alias QPBX.Web.Api.{Page, Schemas}

  def operation(:index),
    do: %{
      summary: "List extensions",
      tag: "Extensions",
      scope: "read",
      audience: :tenant,
      params: Page.params(),
      response: {:list, Schemas.extension()}
    }

  def operation(:show),
    do: %{
      summary: "Get an extension",
      tag: "Extensions",
      scope: "read",
      audience: :tenant,
      response: Schemas.extension()
    }

  def operation(:create),
    do: %{
      summary: "Create an extension",
      tag: "Extensions",
      scope: "write",
      audience: :tenant,
      body: Schemas.extension_input(),
      status: 201,
      response: Schemas.extension()
    }

  def index(conn, params) do
    case Page.paginate(Core.list_extensions(conn.assigns.current_scope), params) do
      {:ok, page, next} ->
        json(conn, %{data: Enum.map(page, &Schemas.render/1), next_cursor: next})

      {:error, message} ->
        {:error, {:bad_request, message}}
    end
  end

  def show(conn, %{"id" => id}) do
    # Another tenant's id is simply not found (tenant filter and row-level security).
    json(conn, %{data: conn.assigns.current_scope |> Core.get_extension!(id) |> Schemas.render()})
  end

  def create(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, ext} <- Core.create_extension(scope, params, conn.assigns.api_key) do
      ext = Core.get_extension!(scope, ext.id)
      conn |> put_status(201) |> json(%{data: Schemas.render(ext)})
    end
  end
end
