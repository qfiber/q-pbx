defmodule QPBX.Web.Api.MeController do
  @moduledoc "`GET /v1/me`: the key making the request (to test a key)."
  use QPBX.Web, :api_controller

  def operation(:show),
    do:
      op("API keys", "The API key making the request", "read", :any,
        response: Schemas.of(QPBX.Core.ApiKey, "ApiKey")
      )

  def show(conn, _params), do: data(conn, conn.assigns.api_key)
end
