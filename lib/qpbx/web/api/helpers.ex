defmodule QPBX.Web.Api.Helpers do
  @moduledoc """
  Imported into every API controller: one-line operation descriptions (`op/5`) and replies.
  Security is not here: `QPBX.Web.Api.Auth` (key, rate limit) runs in the router and
  `QPBX.Web.Api.Authorize` (scope, key kind) in every API controller, both from these
  descriptions.
  """
  import Plug.Conn
  alias QPBX.Web.Api.{Fallback, Page, Schemas}

  @doc """
  An operation: tag, summary, scope (`read`, `write`, `calls`, `fax`, `admin`), audience
  (`:tenant`, `:platform`, `:any`); options `response` (a schema, `{:list, schema}`, or nil
  for 204), `body`, `params`, `status`, `description`.
  """
  def op(tag, summary, scope, audience, opts \\ []),
    do: Map.merge(%{tag: tag, summary: summary, scope: scope, audience: audience}, Map.new(opts))

  @doc "Replies with `%{data: ...}`, the record rendered."
  def data(conn, value, status \\ 200),
    do: conn |> put_status(status) |> Phoenix.Controller.json(%{data: Schemas.render(value)})

  @doc "Replies with one page of a fully loaded list."
  def paged(conn, items, params) do
    case Page.paginate(items, params) do
      {:ok, page, next} ->
        Phoenix.Controller.json(conn, %{data: Schemas.render(page), next_cursor: next})

      {:error, message} ->
        Fallback.call(conn, {:error, {:bad_request, message}})
    end
  end

  @doc """
  Replies to a Core result: `{:ok, rec}` with the record (`status`), `:ok` or `{:ok, _}` with
  `nil` render as 204, errors through `QPBX.Web.Api.Fallback`.
  """
  def reply(conn, result, status \\ 200)
  def reply(conn, :ok, _), do: send_resp(conn, 204, "")
  def reply(conn, {:ok, _}, 204), do: send_resp(conn, 204, "")
  def reply(conn, {:ok, rec}, status), do: data(conn, rec, status)
  def reply(conn, {:ok, rec, _}, status), do: data(conn, rec, status)
  def reply(conn, nil, _), do: Fallback.call(conn, {:error, :not_found})
  def reply(conn, error, _), do: Fallback.call(conn, error)

  @doc "Spec parameter for a query filter."
  def query(name, description, schema \\ %{type: "string"}),
    do: %{name: name, in: "query", description: description, schema: schema}
end
