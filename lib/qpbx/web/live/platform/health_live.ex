defmodule QPBX.Web.Platform.HealthLive do
  @moduledoc """
  The server's health checks, one row each: what it checks, its result, and when it last ran
  (every 10 seconds; "Check now" runs them at once). The same results feed `/health`, the
  dashboard and the health alerts.
  """
  use QPBX.Web, :live_view
  import QPBX.Web.Dashboard, only: [dot: 1]
  alias QPBX.Web.Health

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(10_000, :refresh)
    {:ok, socket |> assign(page_title: gettext("Server health")) |> load(Health.current())}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket, Health.current())}

  @impl true
  def handle_event("check", _params, socket) do
    result = Health.run()
    :ok = Health.put(result)
    {:noreply, socket |> load(result) |> put_flash(:info, gettext("Checked just now."))}
  end

  defp load(socket, health),
    do: assign(socket, health: health, components: Enum.sort_by(health.components, &elem(&1, 0)))

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
        {gettext("Server health")}
        <:subtitle>
          {gettext("Checked every 10 seconds; a change that holds for two checks raises an alert.")}
        </:subtitle>
        <:actions>
          <.button phx-click="check" id="check-now">
            <.icon name="hero-arrow-path" class="size-4" /> {gettext("Check now")}
          </.button>
        </:actions>
      </.header>

      <div class="flex flex-wrap items-center gap-3 text-sm" id="overall">
        <span class={["badge", overall_class(@health.status)]}>{overall(@health.status)}</span>
        <span :if={@health.checked_at} class="text-muted">
          {gettext("Last check: %{time} UTC",
            time: Calendar.strftime(@health.checked_at, "%Y-%m-%d %H:%M:%S")
          )}
        </span>
      </div>

      <.table id="components" rows={@components} row_id={fn {name, _} -> "component-#{name}" end}>
        <:col :let={{name, c}} label={gettext("Component")}>
          <div class="flex items-center gap-2 font-medium">
            <.dot status={to_string(c.status)} />{component(name)}
          </div>
        </:col>
        <:col :let={{name, _}} label={gettext("What it checks")}>
          <span class="text-sm text-muted">{checks(name)}</span>
        </:col>
        <:col :let={{_, c}} label={gettext("Result")}>
          <span class="font-medium">{status(c.status)}</span>
          <span class="block text-xs text-muted" dir="ltr">{c.detail}</span>
        </:col>
      </.table>
    </Layouts.app>
    """
  end

  defp overall("ok"), do: gettext("Healthy")
  defp overall("degraded"), do: gettext("Degraded")
  defp overall(_), do: gettext("Down")

  defp overall_class("ok"), do: "badge-success"
  defp overall_class("degraded"), do: "badge-warning"
  defp overall_class(_), do: "badge-error"

  defp status(:ok), do: gettext("OK")
  defp status(:warning), do: gettext("Warning")
  defp status(:error), do: gettext("Error")
  defp status(:not_configured), do: gettext("Not set up")
  defp status(other), do: to_string(other)

  @doc false
  def component(:postgres), do: "PostgreSQL"
  def component(:freeswitch), do: "FreeSWITCH"
  def component(:kamailio), do: "Kamailio"
  def component(:disk), do: gettext("Disk space")
  def component(:certificate), do: gettext("Certificates")
  def component(:backups), do: gettext("Backups")
  def component(:oban_backlog), do: gettext("Background jobs")
  def component(:trunk_registrations), do: gettext("Trunks")
  def component(other), do: to_string(other)

  defp checks(:postgres), do: gettext("The database answers a query.")

  defp checks(:freeswitch),
    do: gettext("FreeSWITCH (calls, voicemail, fax) accepts a connection on its event socket.")

  defp checks(:kamailio),
    do: gettext("Kamailio (the SIP edge every phone and carrier talks to) answers.")

  defp checks(:disk),
    do:
      gettext("Free space on the system and data disks: a warning under 15%, an error under 5%.")

  defp checks(:certificate),
    do:
      gettext("The TLS certificates (the portal's and each tenant's) are valid for 14 more days.")

  defp checks(:backups),
    do: gettext("Last night's database and file backups succeeded (a warning after 26 hours).")

  defp checks(:oban_backlog),
    do: gettext("Background jobs (emails, webhooks) waiting to run: a warning over 1,000.")

  defp checks(:trunk_registrations),
    do: gettext("Every carrier trunk has an address answering, or is registered.")

  defp checks(_), do: ""
end
