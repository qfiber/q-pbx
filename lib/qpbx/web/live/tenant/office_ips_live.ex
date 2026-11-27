defmodule QPBX.Web.Tenant.OfficeIpsLive do
  @moduledoc """
  Tenant admin: the tenant's office IPs. They are allowed for SIP, get higher limits, and are
  never banned automatically.
  """
  use QPBX.Web, :live_view
  alias QPBX.Firewall

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       socket
       |> assign(page_title: gettext("Office IPs"), form: to_form(Firewall.change_entry()))
       |> load()}

  defp load(socket),
    do:
      assign(socket,
        entries:
          Firewall.list_entries(
            level: "tenant",
            tenant_id: socket.assigns.current_scope.tenant_id
          )
      )

  defp params(params, socket),
    do:
      Map.merge(params, %{
        "level" => "tenant",
        "tenant_id" => socket.assigns.current_scope.tenant_id,
        "kind" => "allow",
        "scope" => "sip"
      })

  @impl true
  def handle_event("save", %{"entry" => params}, socket) do
    case Firewall.create_entry(params(params, socket), socket.assigns.current_account) do
      {:ok, e} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{cidr} added.", cidr: e.cidr))
         |> assign(form: to_form(Firewall.change_entry()))
         |> load()}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert)))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    # Only this tenant's entries are listed, and only those can be removed.
    entry =
      Enum.find(socket.assigns.entries, &(&1.id == id)) ||
        raise Ecto.NoResultsError, queryable: Firewall.Entry

    {:ok, e} = Firewall.delete_entry(entry, socket.assigns.current_account)
    {:noreply, socket |> put_flash(:info, gettext("%{cidr} removed.", cidr: e.cidr)) |> load()}
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
        {gettext("Office IPs")}
        <:subtitle>
          {gettext("Your offices' public IP addresses. Phones there are never blocked automatically.")}
        </:subtitle>
      </.header>
      <.table id="office-ips" rows={@entries}>
        <:col :let={e} label={gettext("Address")}><span dir="ltr">{e.cidr}</span></:col>
        <:col :let={e} label={gettext("Description")}>{e.reason}</:col>
        <:action :let={e}>
          <.link
            phx-click="delete"
            phx-value-id={e.id}
            id={"delete-#{e.id}"}
            data-confirm={gettext("Remove %{cidr}?", cidr: e.cidr)}
          >
            {gettext("Remove")}
          </.link>
        </:action>
      </.table>
      <.form for={@form} id="office-ip-form" phx-submit="save" class="mt-4">
        <.input field={@form[:cidr]} label={gettext("IP address or small prefix")} dir="ltr" required />
        <.input field={@form[:reason]} label={gettext("Description (e.g. Tel Aviv office)")} required />
        <.button variant="primary">{gettext("Add")}</.button>
      </.form>
    </Layouts.app>
    """
  end
end
