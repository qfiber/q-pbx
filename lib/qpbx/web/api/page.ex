defmodule QPBX.Web.Api.Page do
  @moduledoc """
  Cursor pagination for API lists: `?limit=` (1 to 200, default 50) and `?cursor=` (the
  previous page's `next_cursor`, opaque). Items are ordered by id, so pages stay stable while
  rows are added or removed.
  shortcut: pages a list already loaded in full, which suits configuration (hundreds of rows);
  large collections (call records) page in the database instead.
  """
  @default 50
  @max 200

  @doc "`{:ok, items, next_cursor}` or `{:error, message}`."
  def paginate(items, params) do
    with {:ok, limit} <- limit(params["limit"]),
         {:ok, after_id} <- cursor(params["cursor"]) do
      rest =
        items
        |> Enum.sort_by(& &1.id)
        |> Enum.drop_while(&(after_id && &1.id <= after_id))

      {page, more} = Enum.split(rest, limit)
      next = if more != [] and page != [], do: encode(List.last(page).id)
      {:ok, page, next}
    end
  end

  defp limit(nil), do: {:ok, @default}

  defp limit(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n in 1..@max -> {:ok, n}
      _ -> {:error, "limit must be a whole number from 1 to #{@max}"}
    end
  end

  defp cursor(nil), do: {:ok, nil}
  defp cursor(""), do: {:ok, nil}

  defp cursor(value) do
    with {:ok, raw} <- Base.url_decode64(value, padding: false),
         {:ok, id} <- Ecto.UUID.cast(raw) do
      {:ok, id}
    else
      _ -> {:error, "cursor is not valid"}
    end
  end

  defp encode(id), do: Base.url_encode64(id, padding: false)

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
