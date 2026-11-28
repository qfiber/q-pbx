defmodule QPBX.Web.Platform.DidsLive do
  @moduledoc "Platform admin: phone numbers, their carrier trunk, their tenant and backup numbers."
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Web.NumberInput

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: gettext("Numbers"),
       trunks: Core.list_trunks(scope),
       tenants: Core.list_tenants()
     )
     |> assign(form: to_form(Core.change_did()))
     |> load()}
  end

  defp load(socket), do: assign(socket, dids: Core.list_dids(socket.assigns.current_scope))

  @impl true
  def handle_event("save", %{"did" => params}, socket) do
    %{current_scope: scope, current_account: actor} = socket.assigns

    params =
      params
      |> NumberInput.normalize(scope, ["number"])
      |> Map.new(fn {k, v} -> {k, if(v == "", do: nil, else: v)} end)

    case Core.create_did(scope, params, actor) do
      {:ok, did} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{number} added.", number: did.number))
         |> assign(form: to_form(Core.change_did()))
         |> load()}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert)))}
    end
  end

  def handle_event("validate", %{"did" => params}, socket),
    do: {:noreply, assign(socket, form: to_form(Core.change_did(%Core.Did{}, params)))}

  def handle_event("assign", %{"id" => id, "tenant_id" => tid}, socket) do
    %{current_scope: scope, current_account: actor} = socket.assigns

    {:ok, _} =
      Core.update_did(
        scope,
        Core.get_did!(scope, id),
        %{tenant_id: if(tid == "", do: nil, else: tid)},
        actor
      )

    {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    %{current_scope: scope, current_account: actor} = socket.assigns
    {:ok, did} = Core.delete_did(scope, Core.get_did!(scope, id), actor)

    {:noreply,
     socket |> put_flash(:info, gettext("%{number} removed.", number: did.number)) |> load()}
  end

  defp name(list, id), do: Enum.find_value(list, "—", &(&1.id == id && &1.name))
  defp number(dids, id), do: Enum.find_value(dids, "—", &(&1.id == id && &1.number))

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
        {gettext("Numbers")}
        <:subtitle>
          {gettext("Phone numbers held at carriers, and the tenant each one rings.")}
        </:subtitle>
      </.header>
      <.live_component
        module={PagedTable}
        id="dids"
        rows={@dids}
        search={&"#{&1.number} #{name(@tenants, &1.tenant_id)} #{name(@trunks, &1.trunk_id)}"}
        placeholder={gettext("Search by number, tenant or trunk")}
        empty={gettext("No numbers yet. Add the first one below.")}
      >
        <:col :let={d} label={gettext("Number")}>
          <span class="font-semibold tabular-nums" dir="ltr">{d.number}</span>
          <span :if={d.alias_of_id} class="block text-xs text-muted">
            {gettext("Backup of %{number}", number: number(@dids, d.alias_of_id))}
          </span>
        </:col>
        <:col :let={d} label={gettext("Trunk")}>
          <.chip>{name(@trunks, d.trunk_id)}</.chip>
        </:col>
        <:col :let={d} label={gettext("Tenant")}>
          <span :if={d.alias_of_id}>{name(@tenants, d.tenant_id)}</span>
          <form :if={!d.alias_of_id} phx-change="assign" phx-value-id={d.id} id={"assign-#{d.id}"}>
            <select name="tenant_id" class="select select-sm" aria-label={gettext("Tenant")}>
              <option value="">{gettext("Not assigned")}</option>
              <option :for={t <- @tenants} value={t.id} selected={t.id == d.tenant_id}>
                {t.name}
              </option>
            </select>
          </form>
        </:col>
        <:action :let={d}>
          <.link
            phx-click="delete"
            phx-value-id={d.id}
            id={"delete-#{d.id}"}
            class="btn btn-ghost btn-xs text-error"
            data-confirm={gettext("Remove %{number}?", number: d.number)}
          >
            <.icon name="hero-trash" class="size-4" /> {gettext("Remove")}
          </.link>
        </:action>
      </.live_component>

      <.form for={@form} id="did-form" phx-change="validate" phx-submit="save">
        <.section
          title={gettext("Add a number")}
          icon="hero-plus"
          hint={
            gettext("A backup number routes like its main number and belongs to the same tenant.")
          }
        >
          <div class="grid sm:grid-cols-2 gap-x-4">
            <.input field={@form[:number]} label={gettext("Number")} dir="ltr" required />
            <.input
              field={@form[:trunk_id]}
              type="select"
              label={gettext("Carrier trunk")}
              prompt={gettext("Choose")}
              options={Enum.map(@trunks, &{&1.name, &1.id})}
            />
            <.input
              field={@form[:tenant_id]}
              type="select"
              label={gettext("Tenant")}
              prompt={gettext("Not assigned")}
              options={Enum.map(@tenants, &{&1.name, &1.id})}
            />
            <.input
              field={@form[:alias_of_id]}
              type="select"
              label={gettext("Backup of (optional)")}
              prompt="—"
              options={for d <- @dids, is_nil(d.alias_of_id), do: {d.number, d.id}}
            />
          </div>
        </.section>
        <.form_actions><.button variant="primary">{gettext("Add")}</.button></.form_actions>
      </.form>
    </Layouts.app>
    """
  end
end
