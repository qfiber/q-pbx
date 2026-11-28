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

      <form id="alert-filter" phx-change="filter" class="flex flex-wrap gap-2 my-2">
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

      <.table id="alerts" rows={@alerts} row_id={&"a-#{&1.id}"}>
        <:col :let={a} label={gettext("Raised")}>
          <span dir="ltr">{Calendar.strftime(a.inserted_at, "%Y-%m-%d %H:%M")}</span>
        </:col>
        <:col :let={a} label={gettext("Severity")}>{severity_label(a.severity)}</:col>
        <:col :let={a} label={gettext("Alert")}>
          {a.title} <span :if={a.count > 1} class="text-sm opacity-70">×{a.count}</span>
        </:col>
        <:col :let={a} label={gettext("State")}>{state_label(a.state)}</:col>
        <:action :let={a}>
          <.link phx-click="open" phx-value-id={a.id} id={"open-#{a.id}"}>{gettext("Details")}</.link>
        </:action>
        <:action :let={a}>
          <.link
            :if={a.state == "open"}
            phx-click="acknowledge"
            phx-value-id={a.id}
            id={"ack-#{a.id}"}
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
          >
            {gettext("Resolve")}
          </.link>
        </:action>
      </.table>

      <div :if={@open} id="deliveries" class="mt-4">
        <h3 class="font-semibold">{gettext("Who was told")}</h3>
        <.table id="delivery-log" rows={@deliveries} row_id={&"d-#{&1.id}"}>
          <:col :let={d} label={gettext("Time")}>
            <span dir="ltr">{Calendar.strftime(d.inserted_at, "%Y-%m-%d %H:%M:%S")}</span>
          </:col>
          <:col :let={d} label={gettext("Channel")}>{d.channel}</:col>
          <:col :let={d} label={gettext("To")}>
            <span dir="ltr" class="break-all">{d.address || d.account_type}</span>
          </:col>
          <:col :let={d} label={gettext("Status")}>
            {status_label(d.status)}
            <span :if={d.reason} class="text-sm opacity-70">({d.reason})</span>
          </:col>
          <:col :let={d} label={gettext("Last answer")}>
            <span dir="ltr" class="text-xs">
              {d.attempts
              |> List.last()
              |> then(&(&1 && (&1["error"] || &1["status"] || &1["result"])))}
            </span>
          </:col>
          <:action :let={d}>
            <.link
              :if={d.channel in ~w(email webhook)}
              phx-click="resend"
              phx-value-id={d.id}
              id={"resend-#{d.id}"}
            >
              {gettext("Send again")}
            </.link>
          </:action>
        </.table>
      </div>

      <form id="test-form" phx-submit="test" class="flex items-end gap-2 mt-6">
        <label class="block">
          <span class="text-sm">{gettext("Send a test notification for")}</span>
          <select name="test[category]" class="select select-sm">
            <option :for={c <- Catalogue.categories()} value={c}>{category_label(c)}</option>
          </select>
        </label>
        <.button id="send-test">{gettext("Send test")}</.button>
      </form>

      <h2 class="text-lg font-semibold mt-8">{gettext("Shared recipients and alert webhooks")}</h2>
      <p class="text-sm opacity-70">
        {gettext(
          "Addresses that get alerts besides the people (for example it@ or billing@), and HTTPS endpoints that receive them signed, like webhooks."
        )}
      </p>

      <div :if={@secret} id="channel-secret" class="alert alert-warning my-4 flex-col items-start">
        <p>{gettext("Copy this signing secret now. It is not shown again.")}</p>
        <code dir="ltr" class="break-all select-all font-mono" id="channel-secret-value">
          {@secret}
        </code>
        <.button phx-click="dismiss" variant="ghost">{gettext("Done")}</.button>
      </div>

      <.table id="alert-channels" rows={@channels} row_id={&"c-#{&1.id}"}>
        <:col :let={c} label={gettext("Kind")}>
          {if c.kind == "email", do: gettext("Email"), else: gettext("Webhook")}
        </:col>
        <:col :let={c} label={gettext("Address")}>
          <span dir="ltr" class="break-all">{c.address}</span>
        </:col>
        <:col :let={c} label={gettext("Categories")}>
          {Enum.map_join(c.categories, ", ", &category_label/1)}
        </:col>
        <:col :let={c} label={gettext("From severity")}>{severity_label(c.min_severity)}</:col>
        <:col :let={c} label={gettext("Status")}>
          {if c.enabled, do: gettext("On"), else: gettext("Off")}
        </:col>
        <:action :let={c}>
          <.link phx-click="toggle_channel" phx-value-id={c.id} id={"toggle-#{c.id}"}>
            {if c.enabled, do: gettext("Turn off"), else: gettext("Turn on")}
          </.link>
        </:action>
        <:action :let={c}>
          <.link
            phx-click="delete_channel"
            phx-value-id={c.id}
            id={"delete-#{c.id}"}
            data-confirm={gettext("Remove %{address}?", address: c.address)}
          >
            {gettext("Remove")}
          </.link>
        </:action>
      </.table>

      <.form
        for={@form}
        as={:channel}
        id="channel-form"
        phx-change="validate_channel"
        phx-submit="add_channel"
        class="mt-4"
      >
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
          options={[{gettext("Generic JSON"), "generic"}, {gettext("Alertmanager"), "alertmanager"}]}
        />
        <.button variant="primary" id="add-channel">{gettext("Add")}</.button>
      </.form>

      <div :if={@current_scope.kind == :platform} class="mt-8">
        <h2 class="text-lg font-semibold">{gettext("Mandatory categories")}</h2>
        <p class="text-sm opacity-70">{gettext("People cannot switch these off.")}</p>
        <form id="mandatory-form" phx-submit="mandatory" class="mt-2">
          <input type="hidden" name="m[categories][]" value="" />
          <label :for={c <- Catalogue.categories()} class="label">
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              name="m[categories][]"
              value={c}
              id={"mandatory-#{c}"}
              checked={c in @mandatory}
            />
            {category_label(c)}
          </label>
          <.button id="save-mandatory">{gettext("Save")}</.button>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
