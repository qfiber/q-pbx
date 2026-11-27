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

  defp load(socket),
    do: assign(socket, extensions: Core.list_extensions(socket.assigns.current_scope))

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
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("Extensions")}
        <:subtitle>
          {gettext("Each extension rings all of its devices. Each device has its own SIP login.")}
        </:subtitle>
      </.header>

      <.table
        id="extensions"
        rows={@extensions}
        row_click={&JS.navigate(~p"/app/extensions/#{&1.id}")}
      >
        <:col :let={e} label={gettext("Number")}><span dir="ltr">{e.number}</span></:col>
        <:col :let={e} label={gettext("Name")}>{e.name}</:col>
        <:col :let={e} label={gettext("Devices")}>{length(e.devices)}</:col>
        <:col :let={e} label={gettext("Do not disturb")}>
          {if e.dnd, do: gettext("On"), else: "—"}
        </:col>
      </.table>

      <h2 class="text-lg font-semibold mt-8">{gettext("New extension")}</h2>
      <.form for={@form} id="extension-form" phx-change="validate" phx-submit="save">
        <.input
          field={@form[:number]}
          label={gettext("Number")}
          inputmode="numeric"
          dir="ltr"
          required
        />
        <.input field={@form[:name]} label={gettext("Name")} required />
        <.button variant="primary">{gettext("Create")}</.button>
      </.form>
    </Layouts.app>
    """
  end
end
