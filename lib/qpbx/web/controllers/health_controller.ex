defmodule QPBX.Web.HealthController do
  use QPBX.Web, :controller
  alias QPBX.Web.Health

  @doc "Public: status only, no details."
  def show(conn, _params) do
    %{status: status} = Health.current()
    conn |> put_status(http_status(status)) |> json(%{status: status})
  end

  @doc "Token required (`Authorization: Bearer <token>`): status per component."
  def details(conn, _params) do
    if authorized?(conn) do
      result = Health.current()

      conn
      |> put_status(http_status(result.status))
      |> json(%{
        status: result.status,
        checked_at: result.checked_at,
        components: result.components
      })
    else
      conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end

  defp http_status("ok"), do: 200
  defp http_status(_), do: 503

  defp authorized?(conn) do
    expected = Application.get_env(:qpbx, :health_token)

    with true <- is_binary(expected) and byte_size(expected) >= 16,
         ["Bearer " <> given] <- get_req_header(conn, "authorization") do
      Plug.Crypto.secure_compare(given, expected)
    else
      _ -> false
    end
  end
end
