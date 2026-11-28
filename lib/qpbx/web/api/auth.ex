defmodule QPBX.Web.Api.Auth do
  @moduledoc """
  First plug of every authenticated `/v1` request: the API key from `Authorization: Bearer`
  (checked in the database on every request, so a revoked key stops at once), then the
  key's rate limit. Assigns `api_key` and `current_scope`.
  """
  @behaviour Plug
  import Plug.Conn
  alias QPBX.Core
  alias QPBX.Web.Api.{Error, RateLimit}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- bearer(conn),
         {:ok, key} <- Core.authenticate_api_key(token) do
      limit = Core.api_rate_limit(key)

      case RateLimit.hit(key.id, limit) do
        {:ok, remaining} ->
          conn
          |> limit_headers(limit, remaining)
          |> assign(:api_key, key)
          |> assign(:current_scope, Core.scope_for(key))

        {:error, retry_after} ->
          conn
          |> limit_headers(limit, 0)
          |> put_resp_header("retry-after", to_string(retry_after))
          |> Error.send(429, "rate_limited", "Too many requests for this key; retry later.")
      end
    else
      {:error, :expired} -> Error.send(conn, 401, "key_expired", "This API key has expired.")
      _ -> Error.send(conn, 401, "unauthorized", "A valid API key is required.")
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp limit_headers(conn, nil, _), do: conn

  defp limit_headers(conn, limit, remaining) do
    conn
    |> put_resp_header("x-ratelimit-limit", to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
  end
end
