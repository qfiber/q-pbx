defmodule QPBX.Web.Platform.NumberingLive do
  @moduledoc """
  Platform admin: the default number format, destination class prefixes (premium entries are
  the high-cost list) and emergency routes.
  """
  use QPBX.Web, :live_view
  alias QPBX.Core

  @impl true
  def mount(_params, _session, socket) do
    trunks = Core.list_trunks(socket.assigns.current_scope)

    {:ok,
     socket |> assign(page_title: gettext("Numbering"), trunks: trunks) |> reset_forms() |> load()}
  end

  defp load(socket) do
    rule = Core.number_rule(socket.assigns.current_scope)

    assign(socket,
      classes: Core.list_number_classes(),
      emergency: Core.list_emergency_routes(),
      rule_form: rule_form(Core.change_number_rule(rule))
    )
  end

  defp reset_forms(socket),
    do:
      assign(socket,
        class_form: to_form(Core.change_number_class()),
        emergency_form: to_form(Core.change_emergency_route())
      )

  defp rule_form(cs) do
    intl = Ecto.Changeset.get_field(cs, :international_prefixes) || []

    cs
    |> to_form(as: :rule)
    |> Map.update!(:params, &Map.put_new(&1, "international_text", Enum.join(intl, ", ")))
  end

  @impl true
  def handle_event("save_rule", %{"rule" => params}, socket) do
    params =
      Map.put(
        params,
        "international_prefixes",
        QPBX.Web.NumberInput.split(params["international_text"])
      )

    case Core.put_number_rule(
           socket.assigns.current_scope,
           params,
           socket.assigns.current_account
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}

      {:error, cs} ->
        {:noreply, assign(socket, rule_form: rule_form(Map.put(cs, :action, :update)))}
    end
  end

  def handle_event("add_class", %{"number_class" => params}, socket) do
    case Core.create_number_class(
           socket.assigns.current_scope,
           params,
           socket.assigns.current_account
         ) do
      {:ok, c} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{prefix} added.", prefix: c.prefix))
         |> reset_forms()
         |> load()}

      {:error, cs} ->
        {:noreply, assign(socket, class_form: to_form(Map.put(cs, :action, :insert)))}
    end
  end

  # Tracking typed values on the server is what lets the forms clear after an add.
  def handle_event("validate_class", %{"number_class" => params}, socket),
    do: {:noreply, assign(socket, class_form: to_form(Core.change_number_class(params)))}

  def handle_event("validate_emergency", %{"emergency_route" => params}, socket),
    do: {:noreply, assign(socket, emergency_form: to_form(Core.change_emergency_route(params)))}

  def handle_event("delete_class", %{"id" => id}, socket) do
    {:ok, _} =
      Core.delete_number_class(socket.assigns.current_scope, id, socket.assigns.current_account)

    {:noreply, load(socket)}
  end

  def handle_event("add_emergency", %{"emergency_route" => params}, socket) do
    case Core.create_emergency_route(
           socket.assigns.current_scope,
           params,
           socket.assigns.current_account
         ) do
      {:ok, e} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{number} added.", number: e.number))
         |> reset_forms()
         |> load()}

      {:error, cs} ->
        {:noreply, assign(socket, emergency_form: to_form(Map.put(cs, :action, :insert)))}
    end
  end

  def handle_event("delete_emergency", %{"id" => id}, socket) do
    {:ok, _} =
      Core.delete_emergency_route(
        socket.assigns.current_scope,
        id,
        socket.assigns.current_account
      )

    {:noreply, load(socket)}
  end

  defp trunk_name(trunks, id), do: Enum.find_value(trunks, "—", &(&1.id == id && &1.name))

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
        {gettext("Numbering")}
        <:subtitle>
          {gettext("How numbers are written, what kind of destination each is, and emergency calls.")}
        </:subtitle>
      </.header>

      <.form for={@rule_form} id="rule-form" phx-submit="save_rule">
        <.section
          title={gettext("Default number format")}
          icon="hero-hashtag"
          hint={gettext("Tenants use this unless they set their own.")}
        >
          <div class="grid sm:grid-cols-2 lg:grid-cols-4 gap-x-4">
            <.input
              field={@rule_form[:country_code]}
              label={gettext("Country code")}
              dir="ltr"
              required
            />
            <.input
              field={@rule_form[:national_prefix]}
              label={gettext("National prefix")}
              dir="ltr"
            />
            <.input
              name="rule[international_text]"
              id="rule_international_text"
              value={@rule_form.params["international_text"]}
              label={gettext("International prefixes")}
              dir="ltr"
              errors={Enum.map(@rule_form[:international_prefixes].errors, &translate_error/1)}
            />
            <.input
              field={@rule_form[:area_code]}
              label={gettext("Area code (optional)")}
              dir="ltr"
            />
          </div>
        </.section>
        <.form_actions><.button variant="primary">{gettext("Save")}</.button></.form_actions>
      </.form>

      <.section
        title={gettext("Destination classes")}
        icon="hero-globe-alt"
        hint={
          gettext(
            "The longest matching prefix decides. Numbers matching none are local at home and international abroad. Premium prefixes form the high-cost list: blocked unless the plan allows premium."
          )
        }
      >
        <div class="space-y-4">
          <.live_component
            module={PagedTable}
            id="classes"
            rows={@classes}
            search={&"#{&1.prefix} #{&1.note}"}
            placeholder={gettext("Search prefixes")}
            empty={gettext("No prefixes yet.")}
          >
            <:col :let={c} label={gettext("Prefix")}>
              <span class="font-semibold tabular-nums" dir="ltr">{c.prefix}</span>
            </:col>
            <:col :let={c} label={gettext("Class")}>
              <.chip tone={if c.class == "premium", do: :warm, else: :accent}>
                {class_label(c.class)}
              </.chip>
            </:col>
            <:col :let={c} label={gettext("Note")}><span class="text-muted">{c.note}</span></:col>
            <:action :let={c}>
              <.link
                phx-click="delete_class"
                phx-value-id={c.id}
                id={"delete-class-#{c.id}"}
                class="btn btn-ghost btn-xs text-error"
              >
                <.icon name="hero-trash" class="size-4" /> {gettext("Remove")}
              </.link>
            </:action>
          </.live_component>
          <.form
            for={@class_form}
            id="class-form"
            phx-change="validate_class"
            phx-submit="add_class"
          >
            <div class="grid sm:grid-cols-[1fr_1fr_1fr_auto] gap-x-4 items-end">
              <.input
                field={@class_form[:prefix]}
                label={gettext("Prefix (e.g. +9725)")}
                dir="ltr"
                required
              />
              <.input
                field={@class_form[:class]}
                type="select"
                label={gettext("Class")}
                options={Enum.map(Core.Plan.destination_classes(), &{class_label(&1), &1})}
              />
              <.input field={@class_form[:note]} label={gettext("Note")} />
              <.button variant="primary" class="mb-2">
                <.icon name="hero-plus" class="size-4" /> {gettext("Add")}
              </.button>
            </div>
          </.form>
        </div>
      </.section>

      <.section
        title={gettext("Emergency routes")}
        icon="hero-lifebuoy"
        hint={
          gettext(
            "Emergency numbers always go out through their trunk and skip spend and minute limits."
          )
        }
      >
        <div class="space-y-4">
          <.live_component
            module={PagedTable}
            id="emergency"
            rows={@emergency}
            empty={gettext("No emergency numbers yet.")}
          >
            <:col :let={e} label={gettext("Number")}>
              <span class="font-semibold tabular-nums" dir="ltr">{e.number}</span>
            </:col>
            <:col :let={e} label={gettext("Trunk")}>
              <.chip>{trunk_name(@trunks, e.trunk_id)}</.chip>
            </:col>
            <:action :let={e}>
              <.link
                phx-click="delete_emergency"
                phx-value-id={e.id}
                id={"delete-emergency-#{e.id}"}
                class="btn btn-ghost btn-xs text-error"
              >
                <.icon name="hero-trash" class="size-4" /> {gettext("Remove")}
              </.link>
            </:action>
          </.live_component>
          <.form
            for={@emergency_form}
            id="emergency-form"
            phx-change="validate_emergency"
            phx-submit="add_emergency"
          >
            <div class="grid sm:grid-cols-[1fr_1fr_auto] gap-x-4 items-end">
              <.input
                field={@emergency_form[:number]}
                label={gettext("Number (e.g. 100)")}
                dir="ltr"
                required
              />
              <.input
                field={@emergency_form[:trunk_id]}
                type="select"
                label={gettext("Trunk")}
                prompt={gettext("Choose")}
                options={Enum.map(@trunks, &{&1.name, &1.id})}
              />
              <.button variant="primary" class="mb-2">
                <.icon name="hero-plus" class="size-4" /> {gettext("Add")}
              </.button>
            </div>
          </.form>
        </div>
      </.section>
    </Layouts.app>
    """
  end

  defp class_label("local"), do: gettext("Local")
  defp class_label("mobile"), do: gettext("Mobile")
  defp class_label("international"), do: gettext("International")
  defp class_label("premium"), do: gettext("Premium")
end
