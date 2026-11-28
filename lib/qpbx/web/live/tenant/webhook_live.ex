defmodule QPBX.Web.Tenant.WebhookLive do
  @moduledoc """
  Tenant admin: one webhook endpoint. Change it, turn it off, rotate its secret, remove it;
  the delivery log (newest first) with every attempt and the answer, and resend.
  """
  use QPBX.Web, :live_view
  import QPBX.Web.Tenant.WebhooksLive, only: [webhook_secret: 1, webhook_fields: 1]
  alias QPBX.Integrations

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Integrations.get_webhook(socket.assigns.current_scope, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Not found."))
         |> push_navigate(to: ~p"/app/webhooks")}

      e ->
        {:ok,
         socket
         |> assign(page_title: gettext("Webhook"), secret: nil, open: nil)
         |> assign_endpoint(e)}
    end
  end

  defp assign_endpoint(socket, e) do
    assign(socket,
      endpoint: e,
      form: to_form(Integrations.change_webhook(e), as: :endpoint),
      deliveries: Integrations.list_webhook_deliveries(socket.assigns.current_scope, e, 50)
    )
  end

  @impl true
  def handle_event("validate", %{"endpoint" => params}, socket),
    do:
      {:noreply,
       assign(socket,
         form:
           to_form(
             Map.put(
               Integrations.change_webhook(socket.assigns.endpoint, params),
               :action,
               :validate
             ),
             as: :endpoint
           )
       )}

  def handle_event("save", %{"endpoint" => params}, socket) do
    %{current_scope: scope, current_account: me, endpoint: e} = socket.assigns

    case Integrations.update_webhook(scope, e, params, me) do
      {:ok, e} ->
        {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> assign_endpoint(e)}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :update), as: :endpoint))}
    end
  end

  def handle_event("toggle", _, socket) do
    %{current_scope: scope, current_account: me, endpoint: e} = socket.assigns
    {:ok, e} = Integrations.update_webhook(scope, e, %{enabled: not e.enabled}, me)
    {:noreply, assign_endpoint(socket, e)}
  end

  def handle_event("rotate", _, socket) do
    %{current_scope: scope, current_account: me, endpoint: e} = socket.assigns
    {:ok, e, secret} = Integrations.rotate_webhook_secret(scope, e, me)
    {:noreply, socket |> assign(secret: secret) |> assign_endpoint(e)}
  end

  def handle_event("dismiss", _, socket), do: {:noreply, assign(socket, secret: nil)}

  def handle_event("delete", _, socket) do
    %{current_scope: scope, current_account: me, endpoint: e} = socket.assigns
    {:ok, _} = Integrations.delete_webhook(scope, e, me)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Webhook removed."))
     |> push_navigate(to: ~p"/app/webhooks")}
  end

  def handle_event("open", %{"id" => id}, socket),
    do: {:noreply, assign(socket, open: if(socket.assigns.open == id, do: nil, else: id))}

  def handle_event("resend", %{"id" => id}, socket) do
    %{current_scope: scope, current_account: me} = socket.assigns

    case Integrations.get_webhook_delivery(scope, id) do
      nil ->
        {:noreply, socket}

      d ->
        {:ok, _} = Integrations.resend_webhook_delivery(scope, d, me)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Sent again."))
         |> assign_endpoint(socket.assigns.endpoint)}
    end
  end

  def handle_event("refresh", _, socket),
    do: {:noreply, assign_endpoint(socket, socket.assigns.endpoint)}

  defp status_label("delivered"), do: gettext("Delivered")
  defp status_label("dead"), do: gettext("Given up")
  defp status_label(_), do: gettext("Retrying")

  defp time(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")

  defp attempt_result(%{"status" => s}) when is_integer(s), do: "HTTP #{s}"
  defp attempt_result(%{"error" => e}), do: e
  defp attempt_result(_), do: ""

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
        <span dir="ltr" class="break-all">{@endpoint.url}</span>
        <:subtitle>
          <.chip tone={if @endpoint.enabled, do: :ok, else: :plain}>
            {if @endpoint.enabled, do: gettext("On"), else: gettext("Off")}
          </.chip>
          <.link navigate={~p"/app/webhooks"} class="ms-2 text-secondary hover:underline">
            {gettext("All webhooks")}
          </.link>
        </:subtitle>
        <:actions>
          <.button phx-click="toggle" id="toggle">
            {if @endpoint.enabled, do: gettext("Turn off"), else: gettext("Turn on")}
          </.button>
          <.button
            phx-click="rotate"
            id="rotate"
            data-confirm={gettext("Make a new secret? The current one stops working at once.")}
          >
            {gettext("New secret")}
          </.button>
          <.button
            phx-click="delete"
            id="delete"
            class="btn text-error"
            data-confirm={gettext("Remove this webhook and its delivery log?")}
          >
            {gettext("Remove")}
          </.button>
        </:actions>
      </.header>

      <.webhook_secret :if={@secret} secret={@secret} />

      <.form for={@form} as={:endpoint} id="webhook-form" phx-change="validate" phx-submit="save">
        <.section title={gettext("Settings")} icon="hero-cog-6-tooth">
          <.webhook_fields form={@form} />
        </.section>
        <.form_actions><.button variant="primary">{gettext("Save")}</.button></.form_actions>
      </.form>

      <.section
        title={gettext("Deliveries")}
        icon="hero-paper-airplane"
        hint={gettext("Every event sent here, its answer and its retries.")}
      >
        <div class="space-y-3">
          <.button phx-click="refresh" variant="ghost" id="refresh">
            <.icon name="hero-arrow-path" class="size-4" /> {gettext("Refresh")}
          </.button>
          <.live_component
            module={PagedTable}
            id="deliveries"
            rows={@deliveries}
            search={& &1.event_type}
            placeholder={gettext("Search by event")}
            empty={gettext("Nothing sent yet.")}
          >
            <:col :let={d} label={gettext("Time")}><span dir="ltr">{time(d.inserted_at)}</span></:col>
            <:col :let={d} label={gettext("Event")}><span dir="ltr">{d.event_type}</span></:col>
            <:col :let={d} label={gettext("Status")}>
              <.chip tone={delivery_tone(d.status)}>{status_label(d.status)}</.chip>
            </:col>
            <:col :let={d} label={gettext("Attempts")}>{length(d.attempts)}</:col>
            <:col :let={d} label={gettext("Last answer")}>
              <span dir="ltr">{d.attempts |> List.last() |> then(&(&1 && attempt_result(&1)))}</span>
            </:col>
            <:action :let={d}>
              <.link
                phx-click="open"
                phx-value-id={d.id}
                id={"open-#{d.id}"}
                class="btn btn-ghost btn-xs"
              >
                {gettext("Details")}
              </.link>
            </:action>
            <:action :let={d}>
              <.link
                phx-click="resend"
                phx-value-id={d.id}
                id={"resend-#{d.id}"}
                class="btn btn-ghost btn-xs"
              >
                <.icon name="hero-arrow-path" class="size-4" /> {gettext("Send again")}
              </.link>
            </:action>
          </.live_component>

          <div
            :for={d <- @deliveries}
            :if={@open == d.id}
            id={"delivery-#{d.id}"}
            class="rounded-[12px] border border-hairline bg-base-100 shadow-card p-4 space-y-2"
            dir="ltr"
          >
            <h3 class="font-semibold">{gettext("Request body")}</h3>
            <pre class="bg-base-200 p-2 text-xs overflow-auto">{d.payload}</pre>
            <h3 class="font-semibold">{gettext("Attempts")}</h3>
            <div :for={a <- d.attempts} class="text-xs border-b border-base-300 py-1">
              <span>{a["at"]}</span>
              · <span>{attempt_result(a)}</span>
              · <span>{a["duration_ms"]} ms</span>
              <pre :if={a["response"]} class="bg-base-200 p-2 overflow-auto">{a["response"]}</pre>
            </div>
          </div>
        </div>
      </.section>
    </Layouts.app>
    """
  end

  defp delivery_tone("delivered"), do: :ok
  defp delivery_tone("dead"), do: :danger
  defp delivery_tone(_), do: :warm
end
