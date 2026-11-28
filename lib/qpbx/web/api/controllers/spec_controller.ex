defmodule QPBX.Web.Api.SpecController do
  @moduledoc """
  `GET /v1/openapi.json` (the OpenAPI document) and `GET /v1/docs` (the explorer: a page of
  this app with its own script, so the portal's CSP holds). Both are public: the document
  describes the software, not any tenant's data.
  """
  use QPBX.Web, :controller

  def show(conn, _params), do: json(conn, QPBX.Web.Api.Spec.document())

  def docs(conn, _params),
    do: conn |> assign(:page_title, gettext("API explorer")) |> render(:docs, layout: false)
end
