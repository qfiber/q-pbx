defmodule QPBX.Web.Tenant.HomeLive do
  @moduledoc """
  The tenant's dashboard: what matters at a glance, each card opening its page. Tenant admins:
  live calls, today's calls, outbound minutes this month, phones online, users, open alerts,
  new voicemail, numbers; the latest calls and open alerts. A tenant user: their own
  extension, voicemail and notifications. Refreshed every 15 seconds.
  """
  use QPBX.Web, :live_view
  import QPBX.Web.Dashboard
  alias QPBX.{Core, Edge, Notify, Telephony}

  @refresh 15_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh, :refresh)
    tenant = Core.my_tenant(socket.assigns.current_scope)
    {:ok, socket |> assign(page_title: gettext("Dashboard"), tenant: tenant) |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  defp load(%{assigns: %{current_account: user}} = socket) do
    if Core.User.role(user) == "tenant_admin",
      do: assign(socket, admin?: true, stats: admin_stats(socket.assigns)),
      else: assign(socket, admin?: false, stats: user_stats(socket.assigns))
  end

  defp admin_stats(%{current_scope: scope, tenant: tenant}) do
    today = DateTime.now!(tenant.timezone) |> DateTime.to_date()
    days = Telephony.usage_daily(scope, 31)
    today_rows = Enum.filter(days, &(&1.day == today))
    month = Enum.filter(days, &(&1.day.year == today.year and &1.day.month == today.month))
    extensions = Core.list_extensions(scope)
    devices = for e <- extensions, d <- e.devices, d.sip_credential, do: d.sip_credential.username
    online = for {u, dom} <- Edge.registered_devices(), dom == tenant.sip_domain, do: u
    alerts = Notify.list_alerts(scope, %{"state" => "open"}, 50)
    vm = Telephony.voicemail_counts(tenant.id)

    %{
      live: length(Telephony.list_live_calls(scope)),
      calls_today: sum(today_rows, :calls),
      answered_today: sum(today_rows, :answered),
      minutes: div(sum(Enum.filter(month, &(&1.direction == "outbound")), :seconds), 60),
      allowance: Core.effective_limits(tenant)[:outbound_minutes_per_month],
      online: Enum.count(devices, &(&1 in online)),
      devices: length(devices),
      extensions: length(extensions),
      users: length(Core.list_users(scope)),
      alerts: length(alerts),
      critical: Enum.count(alerts, &(&1.severity == "critical")),
      recent_alerts: Enum.take(alerts, 5),
      new_vm: vm |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.sum(),
      numbers: length(Core.list_dids(scope)),
      recent_calls: Telephony.search_cdrs(scope, %{}, tenant.timezone, limit: 6)
    }
  end

  defp user_stats(%{current_scope: scope, current_account: user, tenant: tenant}) do
    ext = Core.my_extension(scope)
    {new_vm, _} = (ext && Telephony.voicemail_counts(tenant.id)[ext.id]) || {0, 0}

    %{
      extension: ext,
      new_vm: new_vm,
      unread: Notify.unread_count(user),
      recent_calls:
        if(ext,
          do:
            Telephony.search_cdrs(scope, %{"extension" => ext.number}, tenant.timezone, limit: 6),
          else: []
        )
    }
  end

  defp sum(rows, key), do: rows |> Enum.map(&(Map.get(&1, key) || 0)) |> Enum.sum()

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
        {gettext("Hello, %{name}", name: first_name(@current_account.name))}
        <:subtitle>
          {@tenant.name} · <span dir="ltr">{@tenant.sip_domain}</span>
        </:subtitle>
      </.header>

      <.link
        navigate={~p"/app/account"}
        id="account-summary"
        class={[
          "inline-flex items-center gap-2 rounded-[6px] px-2.5 py-1 text-sm",
          if(Core.totp_enabled?(@current_account),
            do: "bg-ok-pale text-success",
            else: "bg-warm-pale text-warm-ink"
          )
        ]}
      >
        <.icon name="hero-shield-check" class="size-4" />
        {if Core.totp_enabled?(@current_account),
          do: gettext("Two-factor authentication is on."),
          else: gettext("Two-factor authentication is off.")}
      </.link>

      <div :if={@admin?} id="dashboard" class="space-y-6">
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
          <.stat
            id="stat-live"
            navigate={~p"/app/calls"}
            icon="hero-phone-arrow-up-right"
            tone={:accent}
            label={gettext("Live calls")}
            value={@stats.live}
          >
            {gettext("right now")}
          </.stat>
          <.stat
            id="stat-calls"
            navigate={~p"/app/calls"}
            icon="hero-chart-bar"
            tone={:brand}
            label={gettext("Calls today")}
            value={@stats.calls_today}
          >
            {gettext("%{n} answered", n: @stats.answered_today)}
          </.stat>
          <.stat
            id="stat-minutes"
            navigate={~p"/app/calls"}
            icon="hero-clock"
            tone={:warm}
            label={gettext("Outbound minutes this month")}
            value={@stats.minutes}
          >
            <span :if={@stats.allowance}>
              {gettext("of %{n}", n: @stats.allowance)}
              <.meter used={@stats.minutes} of={@stats.allowance} />
            </span>
            <span :if={!@stats.allowance}>{gettext("no monthly cap")}</span>
          </.stat>
          <.stat
            id="stat-online"
            navigate={~p"/app/extensions"}
            icon="hero-signal"
            tone={:ok}
            label={gettext("Phones online")}
            value={"#{@stats.online}/#{@stats.devices}"}
          >
            {gettext("%{n} extensions", n: @stats.extensions)}
          </.stat>
          <.stat
            id="stat-alerts"
            navigate={~p"/app/alerts"}
            icon="hero-bell-alert"
            tone={if @stats.critical > 0, do: :danger, else: :warm}
            label={gettext("Open alerts")}
            value={@stats.alerts}
            alert={@stats.critical > 0}
          >
            {if @stats.critical > 0,
              do: gettext("%{n} critical", n: @stats.critical),
              else: gettext("nothing critical")}
          </.stat>
          <.stat
            id="stat-voicemail"
            navigate={~p"/app/voicemail"}
            icon="hero-inbox"
            tone={:accent}
            label={gettext("New voicemail")}
            value={@stats.new_vm}
          />
          <.stat
            id="stat-users"
            navigate={~p"/app/users"}
            icon="hero-users"
            tone={:brand}
            label={gettext("Users")}
            value={@stats.users}
          />
          <.stat
            id="stat-numbers"
            navigate={~p"/app/numbers"}
            icon="hero-hashtag"
            tone={:ok}
            label={gettext("Numbers")}
            value={@stats.numbers}
          />
        </div>

        <div class="grid lg:grid-cols-2 gap-4">
          <.panel
            id="recent-calls"
            title={gettext("Latest calls")}
            navigate={~p"/app/calls"}
            more={gettext("All calls")}
          >
            <.call_row :for={c <- @stats.recent_calls} call={c} timezone={@tenant.timezone} />
            <p :if={@stats.recent_calls == []} class="px-5 py-6 text-sm text-muted">
              {gettext("No calls yet.")}
            </p>
          </.panel>
          <.panel
            id="recent-alerts"
            title={gettext("Open alerts")}
            navigate={~p"/app/alerts"}
            more={gettext("All alerts")}
          >
            <div :for={a <- @stats.recent_alerts} class="flex items-center gap-3 px-5 py-3">
              <.dot status={a.severity} />
              <span class="flex-1 truncate text-sm">{a.title}</span>
              <span :if={a.count > 1} class="badge badge-ghost badge-sm">×{a.count}</span>
            </div>
            <p
              :if={@stats.recent_alerts == []}
              class="flex items-center gap-2 px-5 py-6 text-sm text-muted"
            >
              <.icon name="hero-check-circle" class="size-5 text-success" />
              {gettext("All clear: no open alerts.")}
            </p>
          </.panel>
        </div>
      </div>

      <div :if={!@admin?} id="dashboard" class="space-y-6">
        <div class="grid grid-cols-2 lg:grid-cols-3 gap-3 sm:gap-4">
          <.stat
            id="stat-extension"
            navigate={~p"/app/me"}
            icon="hero-phone"
            tone={:accent}
            label={gettext("My extension")}
            value={(@stats.extension && @stats.extension.number) || "–"}
          >
            {@stats.extension && @stats.extension.name}
          </.stat>
          <.stat
            id="stat-voicemail"
            navigate={~p"/app/me"}
            icon="hero-inbox"
            tone={:warm}
            label={gettext("New voicemail")}
            value={@stats.new_vm}
          />
          <.stat
            id="stat-notifications"
            navigate={~p"/app/notifications"}
            icon="hero-bell"
            tone={:brand}
            label={gettext("Unread notifications")}
            value={@stats.unread}
          />
        </div>
        <.panel
          :if={@stats.extension}
          id="recent-calls"
          title={gettext("My latest calls")}
          navigate={~p"/app/me"}
          more={gettext("My extension")}
        >
          <.call_row :for={c <- @stats.recent_calls} call={c} timezone={@tenant.timezone} />
          <p :if={@stats.recent_calls == []} class="px-5 py-6 text-sm text-muted">
            {gettext("No calls yet.")}
          </p>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :call, :map, required: true
  attr :timezone, :string, required: true

  defp call_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-5 py-3 text-sm">
      <.icon name={direction_icon(@call.direction)} class="size-4 text-secondary shrink-0" />
      <span class="flex-1 min-w-0 truncate" dir="ltr">
        {@call.caller_number} → {@call.destination}
      </span>
      <.dot status={@call.disposition} />
      <span class="text-muted tabular-nums shrink-0">{time(@call.started_at, @timezone)}</span>
    </div>
    """
  end

  defp direction_icon("inbound"), do: "hero-phone-arrow-down-left"
  defp direction_icon("outbound"), do: "hero-phone-arrow-up-right"
  defp direction_icon(_), do: "hero-phone"

  defp time(nil, _tz), do: ""

  defp time(at, tz),
    do: at |> DateTime.shift_zone!(tz) |> Calendar.strftime("%d/%m %H:%M")

  defp first_name(name), do: name |> to_string() |> String.split(" ") |> hd()
end
