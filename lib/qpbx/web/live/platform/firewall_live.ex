defmodule QPBX.Web.Platform.FirewallLive do
  @moduledoc "Platform admin: allow and block lists, applied to nftables on every server."
  use QPBX.Web, :live_view
  alias QPBX.Firewall

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Firewall"))
     |> assign(form: to_form(Firewall.change_entry(%{"kind" => "allow", "scope" => "all"})))
     |> load()}
  end

  defp load(socket),
    do:
      assign(socket,
        entries: Firewall.list_entries(level: "platform"),
        sync: Firewall.sync_status()
      )

  # Tracking typed values on the server is also what lets the form clear after a save:
  # otherwise the server's empty form never differs from what it rendered before.
  @impl true
  def handle_event("validate", %{"entry" => params}, socket) do
    cs = params |> entry_params() |> Firewall.change_entry() |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("save", %{"entry" => params}, socket) do
    params = entry_params(params)

    case Firewall.create_entry(params, socket.assigns.current_account) do
      {:ok, entry} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{cidr} added. Every server applies it within seconds.", cidr: entry.cidr)
         )
         |> assign(form: to_form(Firewall.change_entry(%{"kind" => "allow", "scope" => "all"})))
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert)))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Firewall.delete_entry(Firewall.get_entry!(id), socket.assigns.current_account) do
      {:ok, entry} ->
        {:noreply,
         socket |> put_flash(:info, gettext("%{cidr} removed.", cidr: entry.cidr)) |> load()}

      {:error, :last_management_entry} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "This is the last management IP. Add another one first, so nobody is locked out."
           )
         )}
    end
  end

  defp entry_params(params),
    do: params |> Map.put("level", "platform") |> Map.update("expires_at", nil, &blank_to_nil/1)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

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
        {gettext("Firewall")}
        <:subtitle>
          {gettext(
            "Allowed addresses always win over blocks. SSH is open only to management IPs (allow, scope SSH or all)."
          )}
        </:subtitle>
      </.header>

      <p :if={@sync && @sync.errors != []} class="alert alert-error" id="sync-errors">
        {gettext("The last sync with nftables reported errors. Check the qpbx-fwd service.")}
      </p>

      <.live_component
        module={PagedTable}
        id="firewall-entries"
        rows={@entries}
        search={&"#{&1.cidr} #{&1.reason}"}
        placeholder={gettext("Search by address or reason")}
        empty={gettext("No entries yet.")}
      >
        <:col :let={e} label={gettext("Address")}>
          <span class="font-semibold tabular-nums" dir="ltr">{e.cidr}</span>
        </:col>
        <:col :let={e} label={gettext("Kind")}>
          <.chip tone={if e.kind == "allow", do: :ok, else: :danger}>{kind_label(e.kind)}</.chip>
        </:col>
        <:col :let={e} label={gettext("Scope")}>
          <.chip tone={:plain}>{scope_label(e.scope)}</.chip>
        </:col>
        <:col :let={e} label={gettext("Reason")}>{e.reason}</:col>
        <:col :let={e} label={gettext("Expires")}>
          <span class="text-muted">{e.expires_at || "—"}</span>
        </:col>
        <:action :let={e}>
          <.link
            phx-click="delete"
            phx-value-id={e.id}
            data-confirm={gettext("Remove %{cidr}?", cidr: e.cidr)}
            id={"delete-#{e.id}"}
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash" class="size-4" /> {gettext("Remove")}
          </.link>
        </:action>
      </.live_component>

      <.form for={@form} id="firewall-form" phx-change="validate" phx-submit="save">
        <.section title={gettext("Add an entry")} icon="hero-plus">
          <div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-x-4">
            <.input
              field={@form[:cidr]}
              label={gettext("IP address or prefix")}
              dir="ltr"
              required
            />
            <.input
              field={@form[:kind]}
              type="select"
              label={gettext("Kind")}
              options={[{kind_label("allow"), "allow"}, {kind_label("block"), "block"}]}
            />
            <.input
              field={@form[:scope]}
              type="select"
              label={gettext("Scope")}
              options={Enum.map(~w(all ssh sip https), &{scope_label(&1), &1})}
            />
            <.input field={@form[:reason]} label={gettext("Reason")} required />
            <.input
              field={@form[:expires_at]}
              type="datetime-local"
              label={gettext("Expires (UTC, optional)")}
            />
          </div>
        </.section>
        <.form_actions><.button variant="primary">{gettext("Add")}</.button></.form_actions>
      </.form>
    </Layouts.app>
    """
  end

  defp kind_label("allow"), do: gettext("Allow")
  defp kind_label("block"), do: gettext("Block")
  defp scope_label("all"), do: gettext("All")
  defp scope_label("ssh"), do: "SSH"
  defp scope_label("sip"), do: "SIP"
  defp scope_label("https"), do: "HTTPS"
end
