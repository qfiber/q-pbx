defmodule QPBX.Web.Account.AlertsLive do
  @moduledoc """
  Admins (tenant admins: the tenant's; platform admins: every alert and the platform's
  channels): alerts with filters, acknowledge and resolve, each alert's delivery log with
  resend, a test notification; shared recipients and alert webhooks; for platform admins, the
  mandatory categories.
  """
  use QPBX.Web, :live_view

  import QPBX.Web.Account.NotificationsLive,
    only: [category_label: 1, severity_label: 1, state_label: 1]

  alias QPBX.Notify
  alias QPBX.Notify.Catalogue

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Alerts"),
       filters: %{},
       open: nil,
       secret: nil,
       form: to_form(Notify.change_alert_channel(), as: :channel)
     )
     |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      alerts: Notify.list_alerts(scope, socket.assigns.filters),
      channels: Notify.list_alert_channels(scope),
      mandatory: Notify.mandatory_categories(),
      deliveries:
        if(socket.assigns.open,
          do: Notify.list_alert_deliveries(scope, socket.assigns.open),
          else: []
        )
    )
  end

  defp platform?(socket), do: socket.assigns.current_scope.kind == :platform

  @impl true
  def handle_event("filter", %{"f" => f}, socket),
    do: {:noreply, socket |> assign(filters: f) |> load()}

  def handle_event("open", %{"id" => id}, socket),
    do:
      {:noreply,
       socket |> assign(open: if(socket.assigns.open == id, do: nil, else: id)) |> load()}

  def handle_event("acknowledge", %{"id" => id}, socket),
    do:
      change(
        socket,
        Notify.acknowledge_alert(
          socket.assigns.current_scope,
          id,
          socket.assigns.current_account
        ),
        gettext("Acknowledged.")
      )

  def handle_event("resolve", %{"id" => id}, socket),
    do:
      change(
        socket,
        Notify.resolve_alert(socket.assigns.current_scope, id, socket.assigns.current_account),
        gettext("Resolved.")
      )

  def handle_event("resend", %{"id" => id}, socket),
    do:
      change(
        socket,
        Notify.resend_notification(
          socket.assigns.current_scope,
          id,
          socket.assigns.current_account
        ),
        gettext("Sent again.")
      )

  def handle_event("test", %{"test" => %{"category" => c}}, socket),
    do:
      change(
        socket,
        Notify.send_test_notification(
          socket.assigns.current_scope,
          c,
          socket.assigns.current_account
        ),
        gettext("Test notification sent.")
      )

  def handle_event("validate_channel", %{"channel" => p}, socket),
    do:
      {:noreply,
       assign(socket,
         form:
           to_form(
             Map.put(
               Notify.change_alert_channel(%Notify.Alerts.Channel{}, p),
               :action,
               :validate
             ),
             as: :channel
           )
       )}

  def handle_event("add_channel", %{"channel" => p}, socket) do
    case Notify.create_alert_channel(
           socket.assigns.current_scope,
           p,
           socket.assigns.current_account
         ) do
      {:ok, _ch, secret} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Added."))
         |> assign(secret: secret, form: to_form(Notify.change_alert_channel(), as: :channel))
         |> load()}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert), as: :channel))}
    end
  end

  def handle_event("toggle_channel", %{"id" => id}, socket) do
    ch = Enum.find(socket.assigns.channels, &(&1.id == id))

    change(
      socket,
      Notify.update_alert_channel(
        socket.assigns.current_scope,
        id,
        %{enabled: !(ch && ch.enabled)},
        socket.assigns.current_account
      ),
      gettext("Saved.")
    )
  end

  def handle_event("delete_channel", %{"id" => id}, socket),
    do:
      change(
        socket,
        Notify.delete_alert_channel(
          socket.assigns.current_scope,
          id,
          socket.assigns.current_account
        ),
        gettext("Removed.")
      )

  def handle_event("mandatory", %{"m" => m}, socket) do
    if platform?(socket) do
      cats = Enum.reject(List.wrap(m["categories"]), &(&1 == ""))

      :ok =
        Notify.set_mandatory_categories(
          socket.assigns.current_scope,
          cats,
          socket.assigns.current_account
        )

      {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss", _, socket), do: {:noreply, assign(socket, secret: nil)}

  defp change(socket, result, message) do
    case result do
      ok when ok == :ok or elem(ok, 0) == :ok ->
        {:noreply, socket |> put_flash(:info, message) |> load()}

      _ ->
        {:noreply, socket |> put_flash(:error, gettext("That could not be done.")) |> load()}
    end
  end

  defp status_label("sent"), do: gettext("Sent")
  defp status_label("pending"), do: gettext("Waiting")
  defp status_label("failed"), do: gettext("Retrying")
  defp status_label("dead"), do: gettext("Given up")
  defp status_label("bounced"), do: gettext("Bounced")
  defp status_label("skipped"), do: gettext("Held back")
  defp status_label(s), do: s

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
        {gettext("Alerts")}
        <:subtitle>{gettext("Problems and notices, who was told, and how.")}</:subtitle>
      </.header>

      <form id="alert-filter" phx-change="filter" class="flex flex-wrap gap-2">
        <select name="f[state]" class="select select-sm">
          <option value="">{gettext("Any state")}</option>
          <option
            :for={s <- ~w(open acknowledged resolved)}
            value={s}
            selected={@filters["state"] == s}
          >
            {state_label(s)}
          </option>
        </select>
        <select name="f[category]" class="select select-sm">
          <option value="">{gettext("Any category")}</option>
          <option :for={c <- Catalogue.categories()} value={c} selected={@filters["category"] == c}>
            {category_label(c)}
          </option>
        </select>
        <select name="f[severity]" class="select select-sm">
          <option value="">{gettext("Any severity")}</option>
          <option :for={s <- Catalogue.severities()} value={s} selected={@filters["severity"] == s}>
            {severity_label(s)}
          </option>
        </select>
      </form>

      <.live_component
        module={PagedTable}
        id="alerts"
        rows={@alerts}
        row_id={&"a-#{&1.id}"}
        search={& &1.title}
        placeholder={gettext("Search alerts")}
        empty={gettext("No alerts. All clear.")}
      >
        <:col :let={a} label={gettext("Alert")}>
          <div class="flex items-center gap-3">
            <span class={[
              "size-2.5 shrink-0 rounded-full",
              case a.severity do
                "critical" -> "bg-error"
                "warning" -> "bg-warning"
                _ -> "bg-secondary"
              end
            ]}>
            </span>
            <div class="min-w-0">
              <span class="font-medium">{a.title}</span>
              <.chip :if={a.count > 1} tone={:plain} class="ms-1">×{a.count}</.chip>
              <span class="block text-xs text-muted" dir="ltr">
                {Calendar.strftime(a.inserted_at, "%Y-%m-%d %H:%M")}
              </span>
            </div>
          </div>
        </:col>
        <:col :let={a} label={gettext("Severity")}>
          <.chip tone={severity_tone(a.severity)}>{severity_label(a.severity)}</.chip>
        </:col>
        <:col :let={a} label={gettext("State")}>
          <.chip tone={state_tone(a.state)}>{state_label(a.state)}</.chip>
        </:col>
        <:action :let={a}>
          <.link phx-click="open" phx-value-id={a.id} id={"open-#{a.id}"} class="btn btn-ghost btn-xs">
            {gettext("Details")}
          </.link>
        </:action>
        <:action :let={a}>
          <.link
            :if={a.state == "open"}
            phx-click="acknowledge"
            phx-value-id={a.id}
            id={"ack-#{a.id}"}
            class="btn btn-ghost btn-xs"
          >
            {gettext("Acknowledge")}
          </.link>
        </:action>
        <:action :let={a}>
          <.link
            :if={a.state != "resolved"}
            phx-click="resolve"
            phx-value-id={a.id}
            id={"resolve-#{a.id}"}
            class="btn btn-ghost btn-xs text-success"
          >
            {gettext("Resolve")}
          </.link>
        </:action>
      </.live_component>

      <div :if={@open} id="deliveries" class="space-y-3">
        <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <h3 class="font-semibold">{gettext("Who was told")}</h3>
          <span class="text-sm text-muted" id="told-summary">{told_summary(@deliveries)}</span>
        </div>
        <.live_component
          module={PagedTable}
          id="delivery-log"
          rows={recipients(@deliveries)}
          search={& &1.name}
          placeholder={gettext("Search people and addresses")}
          empty={gettext("Nobody was told yet.")}
        >
          <:col :let={r} label={gettext("Who")}>
            <span class="font-medium break-all" dir="ltr">{r.name}</span>
          </:col>
          <:col :let={r} label={gettext("How")}>
            <div class="space-y-1">
              <div :for={d <- r.items} class="flex flex-wrap items-center gap-2 text-sm">
                <.chip tone={:plain}>{channel_label(d.channel)}</.chip>
                <.chip tone={delivery_tone(d.status)}>{status_label(d.status)}</.chip>
                <span :if={d.event != "raised"} class="text-xs text-muted">
                  {event_label(d.event)}
                </span>
                <span :if={d.reason} class="text-xs text-muted">({d.reason})</span>
                <span
                  :if={error = last_error(d)}
                  class="text-xs text-muted"
                  title={last_detail(d)}
                >
                  {error}
                </span>
                <.link
                  :if={d.channel in ~w(email webhook) and d.status != "sent"}
                  phx-click="resend"
                  phx-value-id={d.id}
                  id={"resend-#{d.id}"}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-arrow-path" class="size-4" /> {gettext("Send again")}
                </.link>
              </div>
            </div>
          </:col>
        </.live_component>
      </div>

      <form
        id="test-form"
        phx-submit="test"
        class="flex flex-wrap items-end gap-2 rounded-[12px] border border-dashed border-hairline p-4"
      >
        <label class="block">
          <span class="text-sm">{gettext("Send a test notification for")}</span>
          <select name="test[category]" class="select select-sm">
            <option :for={c <- Catalogue.categories()} value={c}>{category_label(c)}</option>
          </select>
        </label>
        <.button id="send-test">{gettext("Send test")}</.button>
      </form>

      <.section
        title={gettext("Shared recipients and alert webhooks")}
        icon="hero-megaphone"
        hint={
          gettext(
            "Addresses that get alerts besides the people (for example it@ or billing@), and HTTPS endpoints that receive them signed, like webhooks."
          )
        }
      >
        <div class="space-y-4">
          <div
            :if={@secret}
            id="channel-secret"
            class="rounded-[12px] border border-warning/50 bg-warm-pale p-4 space-y-2"
          >
            <p class="text-sm font-medium text-warm-ink">
              {gettext("Copy this signing secret now. It is not shown again.")}
            </p>
            <code
              dir="ltr"
              class="block break-all select-all font-mono rounded-[8px] bg-base-100 border border-hairline p-2 text-sm"
              id="channel-secret-value"
            >
              {@secret}
            </code>
            <.button phx-click="dismiss" variant="ghost">{gettext("Done")}</.button>
          </div>

          <.live_component
            module={PagedTable}
            id="alert-channels"
            rows={@channels}
            row_id={&"c-#{&1.id}"}
            empty={gettext("No shared recipients or alert webhooks yet.")}
          >
            <:col :let={c} label={gettext("Kind")}>
              <.chip tone={:plain}>
                {if c.kind == "email", do: gettext("Email"), else: gettext("Webhook")}
              </.chip>
            </:col>
            <:col :let={c} label={gettext("Address")}>
              <span dir="ltr" class="break-all">{c.address}</span>
            </:col>
            <:col :let={c} label={gettext("Categories")}>
              <div class="flex flex-wrap gap-1">
                <.chip :for={cat <- c.categories}>{category_label(cat)}</.chip>
              </div>
            </:col>
            <:col :let={c} label={gettext("From severity")}>{severity_label(c.min_severity)}</:col>
            <:col :let={c} label={gettext("Status")}>
              <.chip tone={if c.enabled, do: :ok, else: :plain}>
                {if c.enabled, do: gettext("On"), else: gettext("Off")}
              </.chip>
            </:col>
            <:action :let={c}>
              <.link
                phx-click="toggle_channel"
                phx-value-id={c.id}
                id={"toggle-#{c.id}"}
                class="btn btn-ghost btn-xs"
              >
                {if c.enabled, do: gettext("Turn off"), else: gettext("Turn on")}
              </.link>
            </:action>
            <:action :let={c}>
              <.link
                phx-click="delete_channel"
                phx-value-id={c.id}
                id={"delete-#{c.id}"}
                class="btn btn-ghost btn-xs text-error"
                data-confirm={gettext("Remove %{address}?", address: c.address)}
              >
                <.icon name="hero-trash" class="size-4" /> {gettext("Remove")}
              </.link>
            </:action>
          </.live_component>

          <.form
            for={@form}
            as={:channel}
            id="channel-form"
            phx-change="validate_channel"
            phx-submit="add_channel"
          >
            <div class="grid sm:grid-cols-2 gap-x-4">
              <.input
                field={@form[:kind]}
                type="select"
                label={gettext("Kind")}
                options={[{gettext("Email"), "email"}, {gettext("Webhook"), "webhook"}]}
              />
              <.input
                field={@form[:address]}
                label={gettext("Email address or HTTPS URL")}
                dir="ltr"
                required
              />
            </div>
            <fieldset class="fieldset mb-2">
              <legend class="fieldset-legend">{gettext("Categories")}</legend>
              <input type="hidden" name="channel[categories][]" value="" />
              <label :for={c <- Catalogue.categories()} class="label">
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  name="channel[categories][]"
                  value={c}
                  id={"cat-#{c}"}
                  checked={c in (@form[:categories].value || [])}
                />
                {category_label(c)}
              </label>
              <p
                :for={msg <- Enum.map(@form[:categories].errors, &translate_error/1)}
                class="text-error text-sm"
              >
                {msg}
              </p>
            </fieldset>
            <div class="grid sm:grid-cols-2 gap-x-4">
              <.input
                field={@form[:min_severity]}
                type="select"
                label={gettext("From severity")}
                options={Enum.map(Catalogue.severities(), &{severity_label(&1), &1})}
              />
              <.input
                field={@form[:format]}
                type="select"
                label={gettext("Webhook format")}
                options={[
                  {gettext("Generic JSON"), "generic"},
                  {gettext("Alertmanager"), "alertmanager"}
                ]}
              />
            </div>
            <.form_actions>
              <.button variant="primary" id="add-channel">{gettext("Add")}</.button>
            </.form_actions>
          </.form>
        </div>
      </.section>

      <.section
        :if={@current_scope.kind == :platform}
        title={gettext("Mandatory categories")}
        icon="hero-lock-closed"
        hint={gettext("People cannot switch these off.")}
      >
        <form id="mandatory-form" phx-submit="mandatory">
          <input type="hidden" name="m[categories][]" value="" />
          <div class="flex flex-wrap gap-x-6 gap-y-2">
            <label
              :for={c <- Catalogue.categories()}
              class="flex items-center gap-2 text-sm cursor-pointer"
            >
              <input
                type="checkbox"
                class="checkbox checkbox-sm checkbox-primary"
                name="m[categories][]"
                value={c}
                id={"mandatory-#{c}"}
                checked={c in @mandatory}
              />
              {category_label(c)}
            </label>
          </div>
          <.form_actions>
            <.button id="save-mandatory" variant="primary">{gettext("Save")}</.button>
          </.form_actions>
        </form>
      </.section>
    </Layouts.app>
    """
  end

  # One row per person or address: their portal entry, email or webhook, each event.
  defp recipients(deliveries) do
    deliveries
    |> Enum.group_by(&(&1.account_id || &1.alert_channel_id || &1.address))
    |> Enum.map(fn {key, ns} ->
      %{
        id: key,
        name: Enum.find_value(ns, & &1.address) || account_label(hd(ns).account_type),
        items: Enum.sort_by(ns, &{&1.channel, &1.inserted_at})
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp told_summary(deliveries) do
    people = deliveries |> recipients() |> length()
    by = Enum.frequencies_by(deliveries, & &1.status)

    [
      ngettext("1 recipient", "%{count} recipients", people),
      by["sent"] && gettext("%{n} sent", n: by["sent"]),
      by["failed"] && gettext("%{n} retrying", n: by["failed"]),
      by["dead"] && gettext("%{n} given up", n: by["dead"]),
      by["bounced"] && gettext("%{n} bounced", n: by["bounced"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp last_error(%{status: s, attempts: attempts}) when s in ~w(failed dead bounced),
    do: attempts |> List.last() |> then(&(&1 && (&1["error"] || &1["status"])))

  defp last_error(_), do: nil

  defp last_detail(d), do: d.attempts |> List.last() |> then(&(&1 && &1["detail"]))

  defp channel_label("portal"), do: gettext("Portal")
  defp channel_label("email"), do: gettext("Email")
  defp channel_label("webhook"), do: gettext("Webhook")
  defp channel_label(c), do: c

  defp account_label("platform_admin"), do: gettext("Platform admin")
  defp account_label("user"), do: gettext("User")
  defp account_label(other), do: to_string(other)

  defp delivery_tone("sent"), do: :ok
  defp delivery_tone("failed"), do: :warm
  defp delivery_tone("skipped"), do: :plain
  defp delivery_tone("pending"), do: :plain
  defp delivery_tone(_), do: :danger
end
