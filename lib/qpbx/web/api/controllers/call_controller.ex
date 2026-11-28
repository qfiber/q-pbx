defmodule QPBX.Web.Api.CallController do
  @moduledoc "Call records, their CSV export and daily usage (tenant keys)."
  use QPBX.Web, :api_controller
  alias QPBX.Telephony
  alias QPBX.Telephony.Cdr

  @filters ~w(from to number direction disposition leg extension)

  defp filter_params,
    do: [
      query("from", "first day (the tenant's time zone)", %{type: "string", format: "date"}),
      query("to", "last day", %{type: "string", format: "date"}),
      query("number", "part of the caller or destination"),
      query("direction", "", %{type: "string", enum: Telephony.cdr_directions()}),
      query("disposition", "", %{type: "string", enum: ~w(answered busy no_answer failed)}),
      query("leg", "a (one row per call, default) or all", %{type: "string", enum: ~w(a all)}),
      query("extension", "one extension's calls (its number)")
    ]

  def operation(:index),
    do:
      op("Calls", "Call records, newest first", "read", :tenant,
        params: Page.params() ++ filter_params(),
        response: {:list, Schemas.of(Cdr, "CallRecord")}
      )

  def operation(:export),
    do:
      op("Calls", "Every matching call record as CSV, oldest first", "read", :tenant,
        params: filter_params(),
        response: {:binary, "text/csv"}
      )

  def operation(:usage),
    do:
      op("Calls", "Daily totals per direction, newest first", "read", :tenant,
        params: [query("days", "how many days back (1 to 366, default 31)", %{type: "integer"})],
        response:
          {:list,
           %{
             type: "object",
             properties: %{
               day: %{type: "string", format: "date"},
               direction: %{type: "string"},
               calls: %{type: "integer"},
               answered: %{type: "integer"},
               seconds: %{type: "integer"}
             }
           }}
      )

  def index(conn, params) do
    case Page.keyset(params) do
      {:ok, limit, before} ->
        rows =
          Telephony.search_cdrs(conn.assigns.current_scope, filters(params), tz(conn),
            limit: limit + 1,
            before: before
          )

        {page, next} = Page.next(rows, limit, :started_at)
        json(conn, %{data: Schemas.render(page), next_cursor: next})

      {:error, message} ->
        {:error, {:bad_request, message}}
    end
  end

  def export(conn, params),
    do:
      QPBX.Web.CallsController.send_csv(
        conn,
        conn.assigns.current_scope,
        filters(params),
        tz(conn)
      )

  def usage(conn, params) do
    days =
      case Integer.parse(params["days"] || "31") do
        {n, ""} when n in 1..366 -> n
        _ -> 31
      end

    json(conn, %{data: Telephony.usage_daily(conn.assigns.current_scope, days), next_cursor: nil})
  end

  defp filters(params), do: Map.take(params, @filters)
  defp tz(conn), do: conn.assigns.api_key.tenant.timezone
end
