defmodule QPBX.Web.Api.Page do
  @moduledoc """
  Cursor pagination for API lists: `?limit=` (1 to 200, default 50) and `?cursor=` (the
  previous page's `next_cursor`, opaque).
  - `paginate/2`: a list already loaded in full (configuration: hundreds of rows at most),
    ordered by id, so pages stay stable while rows are added or removed.
  - `keyset/2` and `next/3`: large collections (call records, the audit log), paged in the
    database by time and id, newest first.
  """
  @default 50
  @max 200

  @doc "`{:ok, items, next_cursor}` or `{:error, message}`."
  def paginate(items, params) do
    with {:ok, limit} <- limit(params),
         {:ok, after_id} <- cursor(params["cursor"], &Ecto.UUID.cast/1) do
      rest =
        items
        |> Enum.sort_by(& &1.id)
        |> Enum.drop_while(&(after_id && &1.id <= after_id))

      {page, more} = Enum.split(rest, limit)
      {:ok, page, if(more != [] and page != [], do: encode(List.last(page).id))}
    end
  end

  @doc "`{:ok, limit, before}` for a database query; `before` is `{datetime, id}` or nil."
  def keyset(params) do
    with {:ok, limit} <- limit(params),
         {:ok, before} <- cursor(params["cursor"], &time_id/1) do
      {:ok, limit, before}
    end
  end

  @doc "The page and its next cursor from `limit + 1` rows fetched; `at` is the time field."
  def next(rows, limit, at) do
    {page, more} = Enum.split(rows, limit)

    cursor =
      if more != [],
        do:
          (last = List.last(page)) &&
            encode(DateTime.to_iso8601(Map.fetch!(last, at)) <> "|" <> last.id)

    {page, cursor}
  end

  defp time_id(raw) do
    with [at, id] <- String.split(raw, "|"),
         {:ok, at, _} <- DateTime.from_iso8601(at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _ -> :error
    end
  end

  defp limit(params) do
    case params["limit"] do
      nil ->
        {:ok, @default}

      value ->
        case Integer.parse(to_string(value)) do
          {n, ""} when n in 1..@max -> {:ok, n}
          _ -> {:error, "limit must be a whole number from 1 to #{@max}"}
        end
    end
  end

  defp cursor(nil, _), do: {:ok, nil}
  defp cursor("", _), do: {:ok, nil}

  defp cursor(value, decode) do
    with {:ok, raw} <- Base.url_decode64(value, padding: false),
         {:ok, v} <- decode.(raw) do
      {:ok, v}
    else
      _ -> {:error, "cursor is not valid"}
    end
  end

  defp encode(text), do: Base.url_encode64(text, padding: false)

  @doc "Spec parameters for a paged list."
  def params,
    do: [
      %{
        name: "limit",
        in: "query",
        schema: %{type: "integer", minimum: 1, maximum: @max, default: @default}
      },
      %{
        name: "cursor",
        in: "query",
        description: "next_cursor of the previous page",
        schema: %{type: "string"}
      }
    ]
end
