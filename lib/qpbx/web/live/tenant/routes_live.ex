defmodule QPBX.Web.Tenant.RoutesLive do
  @moduledoc """
  Tenant admin: outbound routes. Each route lists up to three trunks in failover order: the
  call goes out through the next one when the first is down or refuses it.
  """
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Web.NumberInput

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: gettext("Outbound routes"),
       trunks: Core.trunk_choices(scope),
       editing: nil
     )
     |> new_form()
     |> load()}
  end

  defp load(socket), do: assign(socket, routes: Core.list_routes(socket.assigns.current_scope))
  defp new_form(socket), do: assign(socket, editing: nil, form: route_form(Core.change_route()))

  defp route_form(cs) do
    route = Ecto.Changeset.apply_changes(cs)
    ids = Ecto.Changeset.get_field(cs, :trunk_ids) || []

    cs
    |> to_form(as: :route)
    |> Map.update!(:params, fn p ->
      p
      |> Map.put_new("prefixes_text", Enum.join(route.prefixes || [], ", "))
      |> Map.put_new("trunk_1", Enum.at(ids, 0))
      |> Map.put_new("trunk_2", Enum.at(ids, 1))
      |> Map.put_new("trunk_3", Enum.at(ids, 2))
    end)
  end

  @impl true
  def handle_event("save", %{"route" => params}, socket) do
    %{current_scope: scope, current_account: actor, editing: editing} = socket.assigns
    params = route_params(params)

    result =
      if editing,
        do: Core.update_route(scope, editing, params, actor),
        else: Core.create_route(scope, params, actor)

    case result do
      {:ok, route} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Route %{name} saved.", name: route.name))
         |> new_form()
         |> load()}

      {:error, cs} ->
        {:noreply, assign(socket, form: route_form(Map.put(cs, :action, :insert)))}
    end
  end

  # Tracking typed values on the server is what lets the form clear after a save.
  def handle_event("validate", %{"route" => params}, socket) do
    cs = Core.change_route(socket.assigns.editing || %Core.OutboundRoute{}, route_params(params))
    {:noreply, assign(socket, form: route_form(cs))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    route = Core.get_route!(socket.assigns.current_scope, id)
    {:noreply, assign(socket, editing: route, form: route_form(Core.change_route(route)))}
  end

  def handle_event("cancel", _, socket), do: {:noreply, new_form(socket)}

  def handle_event("delete", %{"id" => id}, socket) do
    %{current_scope: scope, current_account: actor} = socket.assigns
    {:ok, route} = Core.delete_route(scope, Core.get_route!(scope, id), actor)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Route %{name} deleted.", name: route.name))
     |> new_form()
     |> load()}
  end

  defp route_params(params) do
    params
    |> Map.put("prefixes", NumberInput.split(params["prefixes_text"]))
    |> Map.put(
      "trunk_ids",
      Enum.reject([params["trunk_1"], params["trunk_2"], params["trunk_3"]], &(&1 in [nil, ""]))
    )
  end

  defp trunk_names(route, trunks) do
    names = Map.new(trunks, &{&1.id, &1.name})
    Enum.map_join(route.trunk_ids, " → ", &Map.get(names, &1, "?"))
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
        {gettext("Outbound routes")}
        <:subtitle>
          {gettext(
            "Routes are tried from the lowest position. A route without prefixes takes every number."
          )}
        </:subtitle>
      </.header>

      <.live_component
        module={PagedTable}
        id="routes"
        rows={@routes}
        empty={gettext("No routes yet. Without one, outside calls cannot go out.")}
      >
        <:col :let={r} label={gettext("Route")}>
          <div class="flex items-center gap-3">
            <span class="size-8 shrink-0 rounded-[8px] bg-base-200 text-muted grid place-items-center text-sm font-semibold tabular-nums">
              {r.position}
            </span>
            <div>
              <span class="font-semibold">{r.name}</span>
              <span class="block text-xs text-muted" dir="ltr">
                {if r.prefixes == [], do: gettext("every number"), else: Enum.join(r.prefixes, ", ")}
              </span>
            </div>
          </div>
        </:col>
        <:col :let={r} label={gettext("Class")}>
          <.chip>{class_label(r.destination_class)}</.chip>
        </:col>
        <:col :let={r} label={gettext("Trunks in order")}>
          <span class="text-sm" dir="ltr">{trunk_names(r, @trunks)}</span>
        </:col>
        <:col :let={r} label={gettext("Enabled")}>
          <.chip :if={r.enabled} tone={:ok}>{gettext("Yes")}</.chip>
          <.chip :if={!r.enabled} tone={:plain}>{gettext("No")}</.chip>
        </:col>
        <:action :let={r}>
          <.link phx-click="edit" phx-value-id={r.id} id={"edit-#{r.id}"} class="btn btn-ghost btn-xs">
            <.icon name="hero-pencil-square" class="size-4" /> {gettext("Edit")}
          </.link>
        </:action>
        <:action :let={r}>
          <.link
            phx-click="delete"
            phx-value-id={r.id}
            id={"delete-#{r.id}"}
            class="btn btn-ghost btn-xs text-error"
            data-confirm={gettext("Delete route %{name}?", name: r.name)}
          >
            <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
          </.link>
        </:action>
      </.live_component>

      <.form for={@form} id="route-form" phx-change="validate" phx-submit="save">
        <div class="divide-y divide-base-300">
          <.section
            title={if @editing, do: gettext("Edit route"), else: gettext("New route")}
            icon="hero-arrows-right-left"
          >
            <div class="grid sm:grid-cols-2 gap-x-4">
              <.input field={@form[:name]} label={gettext("Name")} required />
              <.input field={@form[:position]} type="number" label={gettext("Position")} min="0" />
              <.input
                field={@form[:destination_class]}
                type="select"
                label={gettext("Destination class")}
                options={Enum.map(Core.Plan.destination_classes(), &{class_label(&1), &1})}
              />
              <.input
                name="route[prefixes_text]"
                id="route_prefixes_text"
                value={@form.params["prefixes_text"]}
                label={
                  gettext(
                    "Number prefixes in E.164, comma-separated (e.g. +972, +9725); empty for all"
                  )
                }
                dir="ltr"
                errors={Enum.map(@form[:prefixes].errors, &translate_error/1)}
              />
            </div>
            <.input field={@form[:enabled]} type="checkbox" label={gettext("Enabled")} />
          </.section>
          <.section
            title={gettext("Trunks")}
            icon="hero-server-stack"
            hint={gettext("Tried in this order: the next one when a trunk fails or refuses.")}
          >
            <div class="grid sm:grid-cols-3 gap-x-4">
              <.input
                :for={n <- 1..3}
                name={"route[trunk_#{n}]"}
                id={"route_trunk_#{n}"}
                type="select"
                value={@form.params["trunk_#{n}"]}
                label={gettext("Trunk %{n}", n: n)}
                options={[{"—", ""} | Enum.map(@trunks, &{trunk_label(&1), &1.id})]}
                errors={
                  if n == 1, do: Enum.map(@form[:trunk_ids].errors, &translate_error/1), else: []
                }
              />
            </div>
          </.section>
          <.section title={gettext("Number changes")} icon="hero-adjustments-horizontal">
            <div class="grid sm:grid-cols-2 gap-x-4">
              <.input
                field={@form[:strip_digits]}
                type="number"
                label={gettext("Digits to remove before sending (after +)")}
                min="0"
              />
              <.input
                field={@form[:add_prefix]}
                label={gettext("Prefix to add before sending")}
                dir="ltr"
              />
            </div>
          </.section>
        </div>
        <.form_actions>
          <.button variant="primary">{gettext("Save")}</.button>
          <.button :if={@editing} type="button" phx-click="cancel" class="btn btn-ghost">
            {gettext("Cancel")}
          </.button>
        </.form_actions>
      </.form>
    </Layouts.app>
    """
  end

  defp trunk_label(%{platform?: true, name: name}),
    do: gettext("%{name} (shared carrier)", name: name)

  defp trunk_label(%{name: name}), do: name

  defp class_label("local"), do: gettext("Local")
  defp class_label("mobile"), do: gettext("Mobile")
  defp class_label("international"), do: gettext("International")
  defp class_label("premium"), do: gettext("Premium")
end
