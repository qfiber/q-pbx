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
      idle_timeout={@idle_timeout}
    >
      <.header>
        <span dir="ltr" class="break-all">{@endpoint.url}</span>
        <:subtitle>{if @endpoint.enabled, do: gettext("On"), else: gettext("Off")}</:subtitle>
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
            data-confirm={gettext("Remove this webhook and its delivery log?")}
          >
            {gettext("Remove")}
          </.button>
        </:actions>
      </.header>

      <.webhook_secret :if={@secret} secret={@secret} />

      <.form
        for={@form}
        as={:endpoint}
        id="webhook-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-4"
      >
        <.webhook_fields form={@form} />
        <.button variant="primary">{gettext("Save")}</.button>
      </.form>

      <h2 class="text-lg font-semibold mt-8 flex items-center gap-2">
        {gettext("Deliveries")}
        <.button phx-click="refresh" variant="ghost" id="refresh">{gettext("Refresh")}</.button>
      </h2>
      <.table id="deliveries" rows={@deliveries}>
        <:col :let={d} label={gettext("Time")}><span dir="ltr">{time(d.inserted_at)}</span></:col>
        <:col :let={d} label={gettext("Event")}><span dir="ltr">{d.event_type}</span></:col>
        <:col :let={d} label={gettext("Status")}>{status_label(d.status)}</:col>
        <:col :let={d} label={gettext("Attempts")}>{length(d.attempts)}</:col>
        <:col :let={d} label={gettext("Last answer")}>
          <span dir="ltr">{d.attempts |> List.last() |> then(&(&1 && attempt_result(&1)))}</span>
        </:col>
        <:action :let={d}>
          <.link phx-click="open" phx-value-id={d.id} id={"open-#{d.id}"}>{gettext("Details")}</.link>
        </:action>
        <:action :let={d}>
          <.link phx-click="resend" phx-value-id={d.id} id={"resend-#{d.id}"}>
            {gettext("Send again")}
          </.link>
        </:action>
      </.table>

      <div
        :for={d <- @deliveries}
        :if={@open == d.id}
        id={"delivery-#{d.id}"}
        class="mt-4 space-y-2"
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
    </Layouts.app>
    """
  end
end
