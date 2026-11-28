defmodule QPBX.Web.Account.NotificationsLive do
  @moduledoc """
  The signed-in person's notifications (the bell's list): mark read, acknowledge an open
  alert; and their own settings: channels per category (mandatory categories always reach
  them), quiet hours (critical alerts ignore them) and the time zone of those hours.
  """
  use QPBX.Web, :live_view
  alias QPBX.Notify
  alias QPBX.Notify.Catalogue

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(page_title: gettext("Notifications")) |> load()}

  defp load(socket) do
    me = socket.assigns.current_account
    pref = Notify.my_preference(me)

    assign(socket,
      items: Notify.list_notifications(me),
      channels: (pref && pref.channels) || %{},
      quiet_start: pref && pref.quiet_start,
      quiet_end: pref && pref.quiet_end,
      timezone: (pref && pref.timezone) || zone(me),
      mandatory: Notify.mandatory_categories()
    )
  end

  defp zone(%QPBX.Core.User{tenant: %{timezone: tz}}), do: tz
  defp zone(_), do: "Etc/UTC"

  @impl true
  def handle_event("read", %{"id" => id}, socket) do
    :ok = Notify.mark_read(socket.assigns.current_account, id)
    {:noreply, load(socket)}
  end

  def handle_event("read_all", _, socket) do
    :ok = Notify.mark_read(socket.assigns.current_account, :all)
    {:noreply, load(socket)}
  end

  def handle_event("acknowledge", %{"id" => id}, socket) do
    %{current_scope: scope, current_account: me} = socket.assigns

    socket =
      case Notify.acknowledge_alert(scope, id, me) do
        {:ok, _} -> put_flash(socket, :info, gettext("Acknowledged."))
        _ -> socket
      end

    {:noreply, load(socket)}
  end

  def handle_event("save_settings", %{"settings" => p}, socket) do
    channels =
      Map.new(Catalogue.categories(), fn c ->
        {c, Enum.reject(List.wrap(p["channels"][c]), &(&1 == ""))}
      end)

    attrs = %{
      channels: channels,
      quiet_start: hour(p["quiet_start"]),
      quiet_end: hour(p["quiet_end"]),
      timezone: p["timezone"]
    }

    case Notify.save_my_preference(socket.assigns.current_account, attrs) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Those settings could not be saved."))}
    end
  end

  defp hour(""), do: nil
  defp hour(nil), do: nil
  defp hour(v), do: String.to_integer(v)

  defp checked?(channels, category, channel, severity_default),
    do: channel in Map.get(channels, category, severity_default)

  @doc false
  def category_label("security"), do: gettext("Security")
  def category_label("health"), do: gettext("Health")
  def category_label("usage"), do: gettext("Usage")
  def category_label("operations"), do: gettext("Operations")
  def category_label("personal"), do: gettext("Personal")

  @doc false
  def severity_label("critical"), do: gettext("Critical")
  def severity_label("warning"), do: gettext("Warning")
  def severity_label(_), do: gettext("Info")

  @doc false
  def state_label("open"), do: gettext("Open")
  def state_label("acknowledged"), do: gettext("Acknowledged")
  def state_label(_), do: gettext("Resolved")

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
        {gettext("Notifications")}
        <:actions>
          <.button phx-click="read_all" id="read-all">
            <.icon name="hero-check" class="size-4" /> {gettext("Mark all read")}
          </.button>
        </:actions>
      </.header>

      <.live_component
        module={PagedTable}
        id="notifications"
        rows={@items}
        row_id={&"n-#{&1.id}"}
        search={&"#{&1.alert.title} #{&1.alert.message}"}
        placeholder={gettext("Search notifications")}
        empty={gettext("No notifications.")}
      >
        <:col :let={n} label={gettext("Alert")}>
          <div class="flex items-start gap-3">
            <span class={[
              "mt-1.5 size-2.5 shrink-0 rounded-full",
              if(n.read_at, do: "bg-base-300", else: "bg-secondary")
            ]}>
            </span>
            <div class="min-w-0">
              <span class={["block", !n.read_at && "font-semibold"]}>{n.alert.title}</span>
              <span class="block text-sm text-muted">{n.alert.message}</span>
              <span class="block text-xs text-muted mt-0.5">
                <span dir="ltr">{Calendar.strftime(n.inserted_at, "%Y-%m-%d %H:%M")}</span>
                · {event_label(n.event)}
              </span>
            </div>
          </div>
        </:col>
        <:col :let={n} label={gettext("Severity")}>
          <.chip tone={severity_tone(n.alert.severity)}>{severity_label(n.alert.severity)}</.chip>
        </:col>
        <:col :let={n} label={gettext("State")}>
          <.chip tone={state_tone(n.alert.state)}>{state_label(n.alert.state)}</.chip>
        </:col>
        <:action :let={n}>
          <.link
            :if={!n.read_at}
            phx-click="read"
            phx-value-id={n.id}
            id={"read-#{n.id}"}
            class="btn btn-ghost btn-xs"
          >
            {gettext("Mark read")}
          </.link>
        </:action>
        <:action :let={n}>
          <.link
            :if={n.alert.state == "open"}
            phx-click="acknowledge"
            phx-value-id={n.alert.id}
            id={"ack-#{n.id}"}
            class="btn btn-ghost btn-xs"
          >
            {gettext("Acknowledge")}
          </.link>
        </:action>
      </.live_component>

      <form id="settings-form" phx-submit="save_settings">
        <div class="divide-y divide-base-300">
          <.section
            title={gettext("My notification settings")}
            icon="hero-adjustments-horizontal"
            hint={
              gettext(
                "Email carries warning and critical alerts and usage reports; other info alerts stay in the portal. Mandatory categories always reach you both ways."
              )
            }
          >
            <div class="overflow-x-auto">
              <table class="table table-sm w-auto">
                <thead>
                  <tr class="text-muted">
                    <th>{gettext("Category")}</th>
                    <th>{gettext("In the portal")}</th>
                    <th>{gettext("Email")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={c <- Catalogue.categories()}>
                    <td class="font-medium">
                      {category_label(c)}
                      <.chip :if={c in @mandatory} tone={:plain} class="ms-1">
                        {gettext("Mandatory")}
                      </.chip>
                    </td>
                    <td :for={ch <- ~w(portal email)}>
                      <input type="hidden" name={"settings[channels][#{c}][]"} value="" />
                      <input
                        type="checkbox"
                        class="checkbox checkbox-sm checkbox-primary"
                        name={"settings[channels][#{c}][]"}
                        value={ch}
                        id={"pref-#{c}-#{ch}"}
                        checked={checked?(@channels, c, ch, Catalogue.default_channels())}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.section>
          <.section
            title={gettext("Quiet hours")}
            icon="hero-moon"
            hint={gettext("In quiet hours no email is sent, except for critical alerts.")}
          >
            <div class="flex flex-wrap gap-4 items-end">
              <label class="block">
                <span class="text-sm">{gettext("Quiet hours from")}</span>
                <select name="settings[quiet_start]" class="select" id="quiet-start">
                  <option value="">{gettext("None")}</option>
                  <option :for={h <- 0..23} value={h} selected={@quiet_start == h}>
                    {String.pad_leading("#{h}", 2, "0")}:00
                  </option>
                </select>
              </label>
              <label class="block">
                <span class="text-sm">{gettext("to")}</span>
                <select name="settings[quiet_end]" class="select" id="quiet-end">
                  <option value="">{gettext("None")}</option>
                  <option :for={h <- 0..23} value={h} selected={@quiet_end == h}>
                    {String.pad_leading("#{h}", 2, "0")}:00
                  </option>
                </select>
              </label>
              <label class="block">
                <span class="text-sm">{gettext("Time zone")}</span>
                <input
                  name="settings[timezone]"
                  value={@timezone}
                  class="input"
                  dir="ltr"
                  id="pref-timezone"
                />
              </label>
            </div>
          </.section>
        </div>
        <.form_actions>
          <.button variant="primary" id="save-settings">{gettext("Save")}</.button>
        </.form_actions>
      </form>
    </Layouts.app>
    """
  end
end
