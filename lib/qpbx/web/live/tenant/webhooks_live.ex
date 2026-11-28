defmodule QPBX.Web.Tenant.WebhooksLive do
  @moduledoc """
  Tenant admin: webhook endpoints. Add one (HTTPS URL, events); its signing secret is shown
  once. Each endpoint's page has its delivery log.
  """
  use QPBX.Web, :live_view
  alias QPBX.Integrations

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Webhooks"),
       secret: nil,
       form: to_form(Integrations.change_webhook())
     )
     |> load()}
  end

  defp load(socket),
    do: assign(socket, endpoints: Integrations.list_webhooks(socket.assigns.current_scope))

  @impl true
  def handle_event("validate", %{"endpoint" => params}, socket),
    do:
      {:noreply,
       assign(socket,
         form:
           to_form(
             Map.put(
               Integrations.change_webhook(%Integrations.Webhooks.Endpoint{}, params),
               :action,
               :validate
             ),
             as: :endpoint
           )
       )}

  def handle_event("save", %{"endpoint" => params}, socket) do
    %{current_scope: scope, current_account: me} = socket.assigns

    case Integrations.create_webhook(scope, params, me) do
      {:ok, _e, secret} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Webhook added."))
         |> assign(secret: secret, form: to_form(Integrations.change_webhook()))
         |> load()}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert), as: :endpoint))}
    end
  end

  def handle_event("dismiss", _, socket), do: {:noreply, assign(socket, secret: nil)}

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
        {gettext("Webhooks")}
        <:subtitle>
          {gettext(
            "Q-PBX sends events (calls, registrations, voicemail, limits) to your HTTPS addresses as they happen, signed with each endpoint's secret."
          )}
        </:subtitle>
      </.header>

      <.webhook_secret :if={@secret} secret={@secret} />

      <.table id="webhooks" rows={@endpoints} row_click={&JS.navigate(~p"/app/webhooks/#{&1.id}")}>
        <:col :let={e} label={gettext("Address")}>
          <span dir="ltr" class="break-all">{e.url}</span>
        </:col>
        <:col :let={e} label={gettext("Events")}>
          <span dir="ltr">{Enum.join(e.event_types, ", ")}</span>
        </:col>
        <:col :let={e} label={gettext("Status")}>
          {if e.enabled, do: gettext("On"), else: gettext("Off")}
        </:col>
      </.table>

      <.form
        for={@form}
        as={:endpoint}
        id="webhook-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-6"
      >
        <.webhook_fields form={@form} />
        <.button variant="primary">{gettext("Add webhook")}</.button>
      </.form>
    </Layouts.app>
    """
  end

  @doc "The secret, once, with how to check a signature."
  attr :secret, :string, required: true

  def webhook_secret(assigns) do
    ~H"""
    <div id="webhook-secret" class="alert alert-warning my-4 flex-col items-start">
      <p>{gettext("Copy this signing secret now. It is not shown again.")}</p>
      <code dir="ltr" class="break-all select-all font-mono" id="webhook-secret-value">
        {@secret}
      </code>
      <p class="text-sm">
        {gettext(
          "Each request carries x-qpbx-timestamp and x-qpbx-signature: v1= followed by the HMAC-SHA256 (hex) of the timestamp, a dot and the body, keyed with this secret."
        )}
      </p>
      <.button phx-click="dismiss" variant="ghost">{gettext("Done")}</.button>
    </div>
    """
  end

  @doc "URL, description and event checkboxes (shared with the endpoint page)."
  attr :form, :any, required: true

  def webhook_fields(assigns) do
    ~H"""
    <.input
      field={@form[:url]}
      label={gettext("HTTPS address")}
      dir="ltr"
      placeholder="https://"
      required
    />
    <.input field={@form[:description]} label={gettext("Description")} />
    <fieldset class="fieldset mb-2">
      <legend class="fieldset-legend">{gettext("Events")}</legend>
      <input type="hidden" name="endpoint[event_types][]" value="" />
      <label :for={t <- Integrations.webhook_event_types()} class="label" dir="ltr">
        <input
          type="checkbox"
          class="checkbox checkbox-sm"
          name="endpoint[event_types][]"
          value={t}
          id={"event-#{t}"}
          checked={t in (@form[:event_types].value || [])}
        />
        {t}
      </label>
      <p
        :for={msg <- Enum.map(@form[:event_types].errors, &translate_error/1)}
        class="text-error text-sm"
      >
        {msg}
      </p>
    </fieldset>
    """
  end
end
