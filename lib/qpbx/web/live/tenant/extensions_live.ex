defmodule QPBX.Web.Tenant.ExtensionsLive do
  @moduledoc "Tenant admin: the tenant's extensions."
  use QPBX.Web, :live_view
  alias QPBX.Core

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Extensions"), form: to_form(Core.change_extension()))
     |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    domain = Core.my_tenant(scope).sip_domain

    assign(socket,
      extensions: Core.list_extensions(scope),
      # SIP user names registered now (Kamailio's memory).
      online: for({u, ^domain} <- QPBX.Edge.registered_devices(), do: u)
    )
  end

  @impl true
  def handle_event("validate", %{"extension" => params}, socket),
    do:
      {:noreply,
       assign(socket,
         form:
           to_form(Map.put(Core.change_extension(%Core.Extension{}, params), :action, :validate))
       )}

  def handle_event("save", %{"extension" => params}, socket) do
    case Core.create_extension(
           socket.assigns.current_scope,
           params,
           socket.assigns.current_account
         ) do
      {:ok, ext} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Extension %{number} created.", number: ext.number))
         |> push_navigate(to: ~p"/app/extensions/#{ext.id}")}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert)))}
    end
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
        {gettext("Extensions")}
        <:subtitle>
          {gettext("Each extension rings all of its devices. Each device has its own SIP login.")}
        </:subtitle>
      </.header>

      <.live_component
        module={PagedTable}
        id="extensions"
        rows={@extensions}
        search={&"#{&1.number} #{&1.name}"}
        placeholder={gettext("Search by number or name")}
        empty={gettext("No extensions yet. Create the first one below.")}
        row_click={&JS.navigate(~p"/app/extensions/#{&1.id}")}
      >
        <:col :let={e} label={gettext("Extension")}>
          <div class="flex items-center gap-3">
            <span class="size-9 shrink-0 rounded-[8px] bg-accent-pale text-secondary grid place-items-center text-sm font-semibold tabular-nums">
              {e.number}
            </span>
            <span class="font-semibold">{e.name}</span>
          </div>
        </:col>
        <:col :let={e} label={gettext("Phones")}>
          <span class="flex items-center gap-2 whitespace-nowrap">
            <span class={[
              "size-2 shrink-0 rounded-full",
              if(online_count(e, @online) > 0, do: "bg-success", else: "bg-base-300")
            ]}>
            </span>
            {gettext("%{online} of %{total} online",
              online: online_count(e, @online),
              total: length(e.devices)
            )}
          </span>
        </:col>
        <:col :let={e} label={gettext("Do not disturb")}>
          <.chip :if={e.dnd} tone={:warm}>{gettext("On")}</.chip>
          <span :if={!e.dnd} class="text-muted">—</span>
        </:col>
      </.live_component>

      <.form for={@form} id="extension-form" phx-change="validate" phx-submit="save">
        <.section title={gettext("New extension")} icon="hero-plus">
          <div class="grid sm:grid-cols-[1fr_2fr_auto] gap-x-4 items-end">
            <.input
              field={@form[:number]}
              label={gettext("Number")}
              inputmode="numeric"
              dir="ltr"
              required
            />
            <.input field={@form[:name]} label={gettext("Name")} required />
            <.button variant="primary" class="mb-2">{gettext("Create")}</.button>
          </div>
        </.section>
      </.form>
    </Layouts.app>
    """
  end

  defp online_count(ext, online),
    do: Enum.count(ext.devices, &(&1.sip_credential && &1.sip_credential.username in online))
end
