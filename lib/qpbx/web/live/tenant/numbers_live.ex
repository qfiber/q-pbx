defmodule QPBX.Web.Tenant.NumbersLive do
  @moduledoc "Tenant admin: where calls to each of the tenant's phone numbers go."
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Core.Numbers
  alias QPBX.Web.NumberInput

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: gettext("Numbers"),
       rule: Core.number_rule(scope),
       extensions: Core.list_extensions(scope)
     )
     |> load()}
  end

  defp load(socket) do
    dids = Core.list_dids(socket.assigns.current_scope)

    forms =
      Map.new(
        dids,
        &{&1.id, to_form(Core.change_did_destination(&1), as: "did", id: "did-#{&1.id}")}
      )

    assign(socket, dids: dids, forms: forms)
  end

  @impl true
  # The form shows the fields of the kind picked (an extension, or a number to dial).
  def handle_event("pick", %{"id" => id, "did" => params}, socket) do
    did = Enum.find(socket.assigns.dids, &(&1.id == id))
    params = Map.update(params, "destination_type", nil, &blank/1)
    form = to_form(Core.change_did_destination(did, params), as: "did", id: "did-#{id}")
    {:noreply, assign(socket, forms: Map.put(socket.assigns.forms, id, form))}
  end

  def handle_event("save", %{"id" => id, "did" => params}, socket) do
    %{current_scope: scope, current_account: actor} = socket.assigns
    did = Enum.find(socket.assigns.dids, &(&1.id == id))

    params =
      params
      |> Map.update("destination_type", nil, &blank/1)
      |> NumberInput.normalize(scope, ["destination_number"])

    case Core.set_did_destination(scope, did, params, actor) do
      {:ok, did} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{number} saved.", number: Numbers.display(did.number, socket.assigns.rule))
         )
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(socket,
           forms:
             Map.put(
               socket.assigns.forms,
               id,
               to_form(Map.put(cs, :action, :update), as: "did", id: "did-#{id}")
             )
         )}
    end
  end

  defp blank(""), do: nil
  defp blank(v), do: v

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
          {gettext(
            "Your phone numbers and where their calls go. The platform adds and removes numbers."
          )}
        </:subtitle>
      </.header>

      <div
        :if={@dids == []}
        id="no-numbers"
        class="rounded-[12px] border border-dashed border-hairline bg-base-100/60 px-6 py-10 text-center text-sm text-muted"
      >
        <.icon name="hero-hashtag" class="size-6 mx-auto mb-2 opacity-60" />
        {gettext("No numbers yet.")}
      </div>

      <div
        :for={did <- @dids}
        class="rounded-[12px] border border-hairline bg-base-100 shadow-card p-5 space-y-3"
        id={"number-#{did.id}"}
      >
        <div class="flex flex-wrap items-center gap-3">
          <span class="size-9 shrink-0 rounded-[8px] grid place-items-center bg-accent-pale text-secondary">
            <.icon name="hero-phone-arrow-down-left" class="size-5" />
          </span>
          <span class="text-lg font-semibold tabular-nums" dir="ltr">
            {Numbers.display(did.number, @rule)}
          </span>
          <.chip :if={did.alias_of_id} tone={:warm}>{gettext("Backup number")}</.chip>
        </div>
        <p :if={did.alias_of_id} class="text-sm text-muted">
          {gettext(
            "Backup number: calls to it go where its main number goes. Ask the main number's carrier to forward to it when this PBX does not answer."
          )}
        </p>
        <.form
          :if={!did.alias_of_id}
          for={@forms[did.id]}
          phx-submit="save"
          phx-change="pick"
          phx-value-id={did.id}
          id={"did-form-#{did.id}"}
        >
          <div class="grid sm:grid-cols-[1fr_1fr_1fr_auto] gap-x-4 items-end">
            <.input
              field={@forms[did.id][:destination_type]}
              type="select"
              label={gettext("Calls go to")}
              options={[
                {gettext("Nowhere (refused)"), ""},
                {gettext("An extension"), "extension"},
                {gettext("Straight to an extension's voicemail"), "voicemail"},
                {gettext("An outside number"), "external"},
                {gettext("Hang up"), "hangup"}
              ]}
            />
            <.input
              :if={type(@forms[did.id]) in ~w(extension voicemail)}
              field={@forms[did.id][:destination_id]}
              type="select"
              label={gettext("Extension")}
              options={[{"—", ""} | Enum.map(@extensions, &{"#{&1.number} #{&1.name}", &1.id})]}
            />
            <.input
              :if={type(@forms[did.id]) == "external"}
              field={@forms[did.id][:destination_number]}
              label={gettext("Outside number")}
              dir="ltr"
            />
            <div :if={type(@forms[did.id]) not in ~w(extension voicemail external)}></div>
            <.button variant="primary" class="mb-2">{gettext("Save")}</.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  defp type(form), do: Phoenix.HTML.Form.input_value(form, :destination_type) |> to_string()
end
