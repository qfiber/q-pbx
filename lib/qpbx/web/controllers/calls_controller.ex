defmodule QPBX.Web.CallsController do
  @moduledoc "CSV export of the tenant's call records (tenant admins), streamed in chunks."
  use QPBX.Web, :controller
  alias QPBX.Core.User

  @header ~w(started_at answered_at ended_at direction leg caller_number caller_name destination
             disposition hangup_cause duration billsec call_uuid)a

  def export(conn, params) do
    if User.role(conn.assigns.current_account) == "tenant_admin" do
      filters = Map.take(params, ~w(from to number direction disposition leg))
      tz = conn.assigns.current_account.tenant.timezone

      conn =
        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header("content-disposition", ~s(attachment; filename="calls.csv"))
        |> put_resp_header("cache-control", "private, no-store")
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, line(Enum.map(@header, &to_string/1)))
      QPBX.Telephony.stream_cdrs(conn.assigns.current_scope, filters, tz, &send_rows(conn, &1))
    else
      conn |> put_status(404) |> text("Not found")
    end
  end

  defp send_rows(conn, stream) do
    Enum.reduce_while(stream, conn, fn c, conn ->
      case chunk(conn, line(Enum.map(@header, &value(Map.get(c, &1))))) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
  end

  defp value(nil), do: ""
  defp value(%DateTime{} = d), do: DateTime.to_iso8601(d)
  defp value(v), do: to_string(v)

  defp line(cells), do: Enum.map_join(cells, ",", &cell/1) <> "\r\n"

  @doc false
  # RFC 4180 quoting; a text starting with = + - @ (a spreadsheet formula) gets a leading quote,
  # except plain numbers such as +972501234567.
  def cell(v) do
    v =
      if Regex.match?(~r/\A[=+\-@\t\r]/, v) and not Regex.match?(~r/\A[+-]?\d+\z/, v),
        do: "'" <> v,
        else: v

    if String.contains?(v, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(v, "\"", "\"\"") <> "\"",
      else: v
  end
end
