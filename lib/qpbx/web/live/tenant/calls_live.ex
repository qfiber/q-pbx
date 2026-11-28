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
      unread={assigns[:unread]}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("Calls")}
        <:subtitle>
          {gettext("Every call of your company. Times are in your company's time zone.")}
        </:subtitle>
        <:actions>
          <.link href={~p"/app/calls/export?#{@filters}"} class="btn" id="export-csv">
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export CSV")}
          </.link>
        </:actions>
      </.header>

      <.form for={@form} id="calls-filter" phx-submit="search">
        <div class="grid sm:grid-cols-3 lg:grid-cols-6 gap-x-4">
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
        <.form_actions>
          <.button variant="primary">
            <.icon name="hero-magnifying-glass" class="size-4" /> {gettext("Search")}
          </.button>
        </.form_actions>
      </.form>

      <div
        :if={@rows == []}
        id="no-calls"
        class="rounded-[12px] border border-dashed border-hairline bg-base-100/60 px-6 py-10 text-center text-sm text-muted"
      >
        <.icon name="hero-phone" class="size-6 mx-auto mb-2 opacity-60" />
        {gettext("No calls found.")}
      </div>
      <.table :if={@rows != []} id="calls" rows={@rows} row_id={&"cdr-#{&1.id}"}>
        <:col :let={c} label={gettext("Call")}>
          <div class="flex items-center gap-3">
            <span class="size-8 shrink-0 rounded-[8px] grid place-items-center bg-accent-pale text-secondary">
              <.icon name={direction_icon(c.direction)} class="size-4" />
            </span>
            <div>
              <span class="text-sm font-medium" dir="ltr">{c.caller_number} → {c.destination}</span>
              <span class="block text-xs text-muted" dir="ltr">{c.local}</span>
            </div>
          </div>
        </:col>
        <:col :let={c} label={gettext("Direction")}>
          <.chip tone={:plain}>{direction(c.direction)}</.chip>
        </:col>
        <:col :let={c} label={gettext("Outcome")}>
          <.chip tone={if c.disposition == "answered", do: :ok, else: :warm}>
            {outcome(c.disposition)}
          </.chip>
        </:col>
        <:col :let={c} label={gettext("Talk time")}>
          <span class="tabular-nums">{duration(c.billsec)}</span>
        </:col>
      </.table>
      <div :if={@page > 1 or @more} class="join">
        <.link
          :if={@page > 1}
          patch={~p"/app/calls?#{Map.put(@filters, "page", @page - 1)}"}
          class="join-item btn btn-sm"
        >
          <.icon name="hero-chevron-left" class="size-4 rtl:rotate-180" /> {gettext("Newer")}
        </.link>
        <.link
          :if={@more}
          patch={~p"/app/calls?#{Map.put(@filters, "page", @page + 1)}"}
          class="join-item btn btn-sm"
          id="older"
        >
          {gettext("Older")} <.icon name="hero-chevron-right" class="size-4 rtl:rotate-180" />
        </.link>
      </div>

      <.section title={gettext("Last 14 days")} icon="hero-chart-bar">
        <.live_component
          module={PagedTable}
          id="usage"
          rows={@usage}
          empty={gettext("No calls yet.")}
        >
          <:col :let={u} label={gettext("Day")}><span dir="ltr">{u.day}</span></:col>
          <:col :let={u} label={gettext("Direction")}>
            <.chip tone={:plain}>{direction(u.direction)}</.chip>
          </:col>
          <:col :let={u} label={gettext("Calls")}><span class="tabular-nums">{u.calls}</span></:col>
          <:col :let={u} label={gettext("Answered")}>
            <span class="tabular-nums">{u.answered}</span>
          </:col>
          <:col :let={u} label={gettext("Talk time")}>
            <span class="tabular-nums">{duration(u.seconds)}</span>
          </:col>
        </.live_component>
      </.section>
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
