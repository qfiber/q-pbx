defmodule QPBX.Web.Platform.DashboardLive do
  @moduledoc """
  The platform dashboard: tenants, live calls, phones online, trunks, open alerts, active
  bans and the server's health, each card opening its page; the health of every component
  and the open alerts below. Refreshed every 15 seconds.
  """
  use QPBX.Web, :live_view
  import QPBX.Web.Dashboard
  alias QPBX.{Core, Edge, Notify, Telephony}
  alias QPBX.Web.Health

  @refresh 15_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh, :refresh)
    {:ok, socket |> assign(page_title: gettext("Dashboard")) |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    scope = socket.assigns.current_scope
    trunks = Map.values(Edge.trunk_status())
    alerts = Notify.list_alerts(scope, %{"state" => "open"}, 50)
    health = Health.current()
    dids = Core.list_dids(scope)

    assign(socket,
      tenants: length(Core.list_tenants()),
      plans: length(Core.list_plans()),
      live: Telephony.active_calls(),
      online: length(Edge.registered_devices()),
      trunks: length(trunks),
      trunks_down: Enum.count(trunks, &(!&1.up)),
      alerts: length(alerts),
      critical: Enum.count(alerts, &(&1.severity == "critical")),
      recent_alerts: Enum.take(alerts, 6),
      bans: length(Edge.list_bans()),
      numbers: length(dids),
      assigned: Enum.count(dids, & &1.tenant_id),
      health: health,
      components: health.components |> Enum.sort_by(&elem(&1, 0))
    )
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
        {gettext("Platform overview")}
        <:subtitle>{gettext("Everything running on this server, at a glance.")}</:subtitle>
      </.header>

      <div id="dashboard" class="space-y-6">
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
          <.stat
            id="stat-health"
            navigate={~p"/platform/health"}
            icon="hero-heart"
            tone={health_tone(@health.status)}
            label={gettext("Server health")}
            value={health_label(@health.status)}
            alert={@health.status == "down"}
          >
            {gettext("%{n} components checked", n: length(@components))}
          </.stat>
          <.stat
            id="stat-tenants"
            navigate={~p"/platform/tenants"}
            icon="hero-building-office-2"
            tone={:brand}
            label={gettext("Tenants")}
            value={@tenants}
          >
            {gettext("%{n} plans", n: @plans)}
          </.stat>
          <.stat
            id="stat-live"
            icon="hero-phone-arrow-up-right"
            tone={:accent}
            label={gettext("Live calls")}
            value={@live}
          >
            {gettext("right now, all tenants")}
          </.stat>
          <.stat
            id="stat-online"
            icon="hero-signal"
            tone={:ok}
            label={gettext("Phones online")}
            value={@online}
          >
            {gettext("registered now")}
          </.stat>
          <.stat
            id="stat-trunks"
            navigate={~p"/platform/trunks"}
            icon="hero-server-stack"
            tone={if @trunks_down > 0, do: :danger, else: :ok}
            label={gettext("Trunks up")}
            value={"#{@trunks - @trunks_down}/#{@trunks}"}
            alert={@trunks_down > 0}
          >
            {cond do
              @trunks == 0 -> gettext("no trunks yet")
              @trunks_down > 0 -> gettext("%{n} down", n: @trunks_down)
              true -> gettext("all carriers answering")
            end}
          </.stat>
          <.stat
            id="stat-alerts"
            navigate={~p"/platform/alerts"}
            icon="hero-bell-alert"
            tone={if @critical > 0, do: :danger, else: :warm}
            label={gettext("Open alerts")}
            value={@alerts}
            alert={@critical > 0}
          >
            {if @critical > 0,
              do: gettext("%{n} critical", n: @critical),
              else: gettext("nothing critical")}
          </.stat>
          <.stat
            id="stat-bans"
            navigate={~p"/platform/protection"}
            icon="hero-no-symbol"
            tone={:warm}
            label={gettext("Blocked addresses")}
            value={@bans}
          >
            {gettext("SIP bans in force")}
          </.stat>
          <.stat
            id="stat-numbers"
            navigate={~p"/platform/numbers"}
            icon="hero-hashtag"
            tone={:brand}
            label={gettext("Numbers")}
            value={@numbers}
          >
            {gettext("%{n} assigned to tenants", n: @assigned)}
          </.stat>
        </div>

        <div class="grid lg:grid-cols-2 gap-4">
          <.panel
            id="health"
            title={gettext("Components")}
            navigate={~p"/platform/health"}
            more={gettext("Details")}
          >
            <div :for={{name, c} <- @components} class="flex items-center gap-3 px-5 py-3 text-sm">
              <.dot status={to_string(c.status)} />
              <span class="w-40 shrink-0 font-medium">{component(name)}</span>
              <span class="flex-1 truncate text-muted" dir="ltr">{c.detail}</span>
            </div>
            <p :if={@components == []} class="px-5 py-6 text-sm text-muted">
              {gettext("The first check has not run yet.")}
            </p>
          </.panel>
          <.panel
            id="recent-alerts"
            title={gettext("Open alerts")}
            navigate={~p"/platform/alerts"}
            more={gettext("All alerts")}
          >
            <div :for={a <- @recent_alerts} class="flex items-center gap-3 px-5 py-3">
              <.dot status={a.severity} />
              <span class="flex-1 truncate text-sm">{a.title}</span>
              <span :if={a.count > 1} class="badge badge-ghost badge-sm">×{a.count}</span>
            </div>
            <p :if={@recent_alerts == []} class="flex items-center gap-2 px-5 py-6 text-sm text-muted">
              <.icon name="hero-check-circle" class="size-5 text-success" />
              {gettext("All clear: no open alerts.")}
            </p>
          </.panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp health_tone("ok"), do: :ok
  defp health_tone("degraded"), do: :warm
  defp health_tone(_), do: :danger

  defp health_label("ok"), do: gettext("Healthy")
  defp health_label("degraded"), do: gettext("Degraded")
  defp health_label(_), do: gettext("Down")

  defp component(name), do: QPBX.Web.Platform.HealthLive.component(name)
end
