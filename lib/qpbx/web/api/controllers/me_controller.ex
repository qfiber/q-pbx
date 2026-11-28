defmodule QPBX.Web.Api.MeController do
  @moduledoc "`GET /v1/me`: the key making the request (to test a key)."
  use QPBX.Web, :api_controller
  alias QPBX.Web.Api.Schemas

  def operation(:show),
    do: %{
      summary: "The API key making the request",
      tag: "Keys",
      scope: "read",
      audience: :any,
      response: Schemas.api_key()
    }

  def show(conn, _params), do: json(conn, %{data: Schemas.render(conn.assigns.api_key)})
end
