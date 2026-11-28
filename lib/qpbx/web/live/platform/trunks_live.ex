defmodule QPBX.Web.Platform.TrunksLive do
  @moduledoc "Platform admin: shared carrier trunks and their signalling addresses."
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Core.{Trunk, TrunkAddress}

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: gettext("Trunks"))}

  @impl true
  def handle_params(params, _url, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :index, _),
    do: assign(socket, trunks: Core.list_trunks(socket.assigns.current_scope), trunk: nil)

  defp apply_action(socket, :new, _) do
    trunk = %Trunk{addresses: [%TrunkAddress{}]}
    assign(socket, trunk: trunk, form: to_form(Core.change_trunk(trunk)))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    trunk = Core.get_trunk!(socket.assigns.current_scope, id)
    assign(socket, trunk: trunk, form: to_form(Core.change_trunk(%{trunk | password: nil})))
  end

  @impl true
  def handle_event("validate", %{"trunk" => params}, socket),
    do:
      {:noreply,
       assign(socket,
         form:
           to_form(
             Map.put(
               Core.change_trunk(socket.assigns.trunk, keep_password(params, socket)),
               :action,
               :validate
             )
           )
       )}

  def handle_event("save", %{"trunk" => params}, socket) do
    %{current_scope: scope, current_account: actor, trunk: trunk} = socket.assigns
    params = keep_password(params, socket)

    result =
      if trunk.id,
        do: Core.update_trunk(scope, trunk, params, actor),
        else: Core.create_trunk(scope, params, actor)

    case result do
      {:ok, t} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Trunk %{name} saved.", name: t.name))
         |> push_navigate(to: ~p"/platform/trunks")}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert)))}
    end
  end

  def handle_event("delete", _, socket) do
    %{current_scope: scope, current_account: actor, trunk: trunk} = socket.assigns

    case Core.delete_trunk(scope, trunk, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Trunk deleted."))
         |> push_navigate(to: ~p"/platform/trunks")}

      {:error, cs} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           cs.errors |> Keyword.values() |> Enum.map_join(" ", &translate_error/1)
         )}
    end
  end

  # An empty password field on an existing trunk keeps the stored password.
  defp keep_password(%{"password" => ""} = params, %{assigns: %{trunk: %Trunk{id: id}}})
       when not is_nil(id),
       do: Map.delete(params, "password")

  defp keep_password(params, _socket), do: params

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      locale={@locale}
      current_account={@current_account}
      unread={assigns[:unread]}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("Trunks")}
        <:subtitle>{gettext("Shared carrier trunks. Every tenant's routes can use them.")}</:subtitle>
        <:actions>
          <.link navigate={~p"/platform/trunks/new"} class="btn btn-primary btn-sm" id="new-trunk">
            {gettext("New trunk")}
          </.link>
        </:actions>
      </.header>
      <.table id="trunks" rows={@trunks} row_click={&JS.navigate(~p"/platform/trunks/#{&1.id}")}>
        <:col :let={t} label={gettext("Name")}>{t.name}</:col>
        <:col :let={t} label={gettext("Authentication")}>{auth_label(t.auth_mode)}</:col>
        <:col :let={t} label={gettext("Addresses")}>
          <span dir="ltr">{Enum.map_join(t.addresses, ", ", & &1.host)}</span>
        </:col>
        <:col :let={t} label={gettext("Fax")}>{t.fax_mode}</:col>
        <:col :let={t} label={gettext("Enabled")}>
          {if t.enabled, do: gettext("Yes"), else: gettext("No")}
        </:col>
      </.table>
    </Layouts.app>
    """
  end

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
        {if @trunk.id, do: @trunk.name, else: gettext("New trunk")}
        <:actions>
          <.link navigate={~p"/platform/trunks"} class="btn btn-ghost btn-sm">
            {gettext("All trunks")}
          </.link>
        </:actions>
      </.header>
      <.form for={@form} id="trunk-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} label={gettext("Name")} required />
        <.input
          field={@form[:auth_mode]}
          type="select"
          label={gettext("Authentication")}
          options={Enum.map(Trunk.auth_modes(), &{auth_label(&1), &1})}
          prompt={gettext("Choose")}
        />
        <.input field={@form[:username]} label={gettext("Registration user")} dir="ltr" />
        <.input
          field={@form[:password]}
          type="password"
          label={
            if @trunk.id,
              do: gettext("Registration password (empty: keep)"),
              else: gettext("Registration password")
          }
          dir="ltr"
          autocomplete="new-password"
        />

        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Signalling addresses")}</legend>
          <p class="text-sm opacity-70">
            {gettext(
              "Calls from any address are accepted. Outbound calls use the lowest priority first; weight shares calls within one priority."
            )}
          </p>
          <.inputs_for :let={a} field={@form[:addresses]}>
            <input type="hidden" name="trunk[addresses_sort][]" value={a.index} />
            <div class="grid sm:grid-cols-6 gap-2 items-end">
              <div class="sm:col-span-2">
                <.input field={a[:host]} label={gettext("IP or host name")} dir="ltr" />
              </div>
              <.input field={a[:port]} type="number" label={gettext("Port")} />
              <.input
                field={a[:transport]}
                type="select"
                label={gettext("Transport")}
                options={[{"UDP", "udp"}, {"TCP", "tcp"}, {"TLS", "tls"}]}
              />
              <.input field={a[:priority]} type="number" label={gettext("Priority")} />
              <label class="label cursor-pointer gap-2 mb-2">
                <input
                  type="checkbox"
                  name="trunk[addresses_drop][]"
                  value={a.index}
                  class="checkbox checkbox-sm"
                />
                {gettext("Remove")}
              </label>
            </div>
          </.inputs_for>
          <input type="hidden" name="trunk[addresses_drop][]" />
          <button
            type="button"
            name="trunk[addresses_sort][]"
            value="new"
            phx-click={JS.dispatch("change")}
            class="btn btn-sm"
            id="add-address"
          >
            {gettext("Add address")}
          </button>
          <p
            :for={msg <- Enum.map(@form[:addresses].errors, &translate_error/1)}
            class="text-error text-sm"
          >
            {msg}
          </p>
        </fieldset>

        <.input
          field={@form[:codecs]}
          type="select"
          multiple
          label={gettext("Codecs")}
          options={Trunk.codecs()}
        />
        <.input
          field={@form[:fax_mode]}
          type="select"
          label={gettext("Fax")}
          options={[
            {gettext("T.38 re-INVITE"), "t38"},
            {gettext("T.38 passthrough"), "t38_passthrough"},
            {gettext("G.711 passthrough"), "g711"}
          ]}
        />
        <.input field={@form[:ecm]} type="checkbox" label={gettext("Fax error correction (ECM)")} />
        <.input
          field={@form[:max_channels]}
          type="number"
          label={gettext("Maximum calls (empty: no limit)")}
        />
        <.input
          field={@form[:caller_id_mode]}
          type="select"
          label={gettext("Caller ID")}
          options={[
            {gettext("May show the tenant's numbers, even from other carriers"), "tenant_numbers"},
            {gettext("Must show its own number"), "own_number"}
          ]}
        />
        <.input field={@form[:default_caller_id]} label={gettext("Its own number (E.164)")} dir="ltr" />
        <.input field={@form[:enabled]} type="checkbox" label={gettext("Enabled")} />
        <.button variant="primary">{gettext("Save")}</.button>
      </.form>
      <div :if={@trunk.id} class="mt-12">
        <.button
          phx-click="delete"
          id="delete-trunk"
          data-confirm={gettext("Delete trunk %{name}?", name: @trunk.name)}
        >
          {gettext("Delete trunk")}
        </.button>
      </div>
    </Layouts.app>
    """
  end

  defp auth_label("ip"), do: gettext("By IP address")
  defp auth_label("registration"), do: gettext("Registration")
end
