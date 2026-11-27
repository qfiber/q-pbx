defmodule QPBX.Web.Tenant.CallsLive do
  @moduledoc """
  Tenant admin: call history (one row per call; every leg on request), searched by date (the
  tenant's time zone), number, direction and outcome, exported as CSV; daily totals.
  """
  use QPBX.Web, :live_view
  alias QPBX.Telephony

  @page 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Calls"),
       usage: Telephony.usage_daily(socket.assigns.current_scope, 14)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Map.take(params, ~w(from to number direction disposition leg))
    page = max(String.to_integer(params["page"] || "1"), 1)
    tz = socket.assigns.current_account.tenant.timezone

    rows =
      Telephony.search_cdrs(socket.assigns.current_scope, filters, tz,
        limit: @page + 1,
        offset: (page - 1) * @page
      )

    {:noreply,
     assign(socket,
       filters: filters,
       form: to_form(filters, as: :f),
       page: page,
       more: length(rows) > @page,
       rows: rows |> Enum.take(@page) |> Enum.map(&Map.put(&1, :local, local(&1.started_at, tz)))
     )}
  rescue
    ArgumentError -> {:noreply, push_patch(socket, to: ~p"/app/calls")}
  end

  defp local(at, tz) do
    case DateTime.shift_zone(at, tz) do
      {:ok, l} -> Calendar.strftime(l, "%Y-%m-%d %H:%M:%S")
      _ -> Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
    end
  end

  @impl true
  def handle_event("search", %{"f" => f}, socket) do
    f = f |> Enum.reject(fn {_k, v} -> v in ["", nil] end) |> Map.new()
    {:noreply, push_patch(socket, to: ~p"/app/calls?#{f}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      locale={@locale}
      current_account={@current_account}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("Calls")}
        <:subtitle>
          {gettext("Every call of your company. Times are in your company's time zone.")}
        </:subtitle>
        <:actions>
          <.link href={~p"/app/calls/export?#{@filters}"} class="btn btn-sm" id="export-csv">
            {gettext("Export CSV")}
          </.link>
        </:actions>
      </.header>

      <.form for={@form} id="calls-filter" phx-submit="search">
        <div class="grid sm:grid-cols-6 gap-2">
          <.input field={@form[:from]} type="date" label={gettext("From")} />
          <.input field={@form[:to]} type="date" label={gettext("To")} />
          <.input field={@form[:number]} label={gettext("Number contains")} dir="ltr" />
          <.input
            field={@form[:direction]}
            type="select"
            label={gettext("Direction")}
            prompt={gettext("All")}
            options={Enum.map(Telephony.cdr_directions(), &{direction(&1), &1})}
          />
          <.input
            field={@form[:disposition]}
            type="select"
            label={gettext("Outcome")}
            prompt={gettext("All")}
            options={Enum.map(~w(answered busy no_answer failed), &{outcome(&1), &1})}
          />
          <.input
            field={@form[:leg]}
            type="select"
            label={gettext("Show")}
            options={[{gettext("One row per call"), "a"}, {gettext("Every leg"), "all"}]}
          />
        </div>
        <.button variant="primary">{gettext("Search")}</.button>
      </.form>

      <p :if={@rows == []} id="no-calls" class="mt-4">{gettext("No calls found.")}</p>
      <.table :if={@rows != []} id="calls" rows={@rows} row_id={&"cdr-#{&1.id}"}>
        <:col :let={c} label={gettext("When")}><span dir="ltr">{c.local}</span></:col>
        <:col :let={c} label={gettext("Direction")}>{direction(c.direction)}</:col>
        <:col :let={c} label={gettext("From")}><span dir="ltr">{c.caller_number}</span></:col>
        <:col :let={c} label={gettext("To")}><span dir="ltr">{c.destination}</span></:col>
        <:col :let={c} label={gettext("Outcome")}>{outcome(c.disposition)}</:col>
        <:col :let={c} label={gettext("Talk time")}>{duration(c.billsec)}</:col>
      </.table>
      <div class="flex gap-2 mt-2">
        <.link
          :if={@page > 1}
          patch={~p"/app/calls?#{Map.put(@filters, "page", @page - 1)}"}
          class="btn btn-sm"
        >
          {gettext("Newer")}
        </.link>
        <.link
          :if={@more}
          patch={~p"/app/calls?#{Map.put(@filters, "page", @page + 1)}"}
          class="btn btn-sm"
          id="older"
        >
          {gettext("Older")}
        </.link>
      </div>

      <h2 class="text-lg font-semibold mt-8">{gettext("Last 14 days")}</h2>
      <p :if={@usage == []}>{gettext("No calls yet.")}</p>
      <.table :if={@usage != []} id="usage" rows={@usage}>
        <:col :let={u} label={gettext("Day")}><span dir="ltr">{u.day}</span></:col>
        <:col :let={u} label={gettext("Direction")}>{direction(u.direction)}</:col>
        <:col :let={u} label={gettext("Calls")}>{u.calls}</:col>
        <:col :let={u} label={gettext("Answered")}>{u.answered}</:col>
        <:col :let={u} label={gettext("Talk time")}>{duration(u.seconds)}</:col>
      </.table>
    </Layouts.app>
    """
  end

  defp direction("inbound"), do: gettext("Inbound")
  defp direction("outbound"), do: gettext("Outbound")
  defp direction(_), do: gettext("Internal")

  defp outcome("answered"), do: gettext("Answered")
  defp outcome("busy"), do: gettext("Busy")
  defp outcome("no_answer"), do: gettext("Not answered")
  defp outcome(_), do: gettext("Failed")

  defp duration(s),
    do: "#{div(s, 60)}:#{s |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
end
