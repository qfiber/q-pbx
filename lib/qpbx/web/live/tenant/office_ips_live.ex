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

  def handle_event("validate", %{"entry" => params}, socket),
    do: {:noreply, assign(socket, form: to_form(Firewall.change_entry(params)))}

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
      unread={assigns[:unread]}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("Office IPs")}
        <:subtitle>
          {gettext("Your offices' public IP addresses. Phones there are never blocked automatically.")}
        </:subtitle>
      </.header>
      <.live_component
        module={PagedTable}
        id="office-ips"
        rows={@entries}
        search={&"#{&1.cidr} #{&1.reason}"}
        placeholder={gettext("Search by address or description")}
        empty={gettext("No office addresses yet.")}
      >
        <:col :let={e} label={gettext("Address")}>
          <span class="font-semibold tabular-nums" dir="ltr">{e.cidr}</span>
        </:col>
        <:col :let={e} label={gettext("Description")}>{e.reason}</:col>
        <:action :let={e}>
          <.link
            phx-click="delete"
            phx-value-id={e.id}
            id={"delete-#{e.id}"}
            class="btn btn-ghost btn-xs text-error"
            data-confirm={gettext("Remove %{cidr}?", cidr: e.cidr)}
          >
            <.icon name="hero-trash" class="size-4" /> {gettext("Remove")}
          </.link>
        </:action>
      </.live_component>
      <.form for={@form} id="office-ip-form" phx-change="validate" phx-submit="save">
        <.section title={gettext("Add an office")} icon="hero-building-office">
          <div class="grid sm:grid-cols-[1fr_2fr_auto] gap-x-4 items-end">
            <.input
              field={@form[:cidr]}
              label={gettext("IP address or small prefix")}
              dir="ltr"
              required
            />
            <.input
              field={@form[:reason]}
              label={gettext("Description (e.g. Tel Aviv office)")}
              required
            />
            <.button variant="primary" class="mb-2">{gettext("Add")}</.button>
          </div>
        </.section>
      </.form>
    </Layouts.app>
    """
  end
end
