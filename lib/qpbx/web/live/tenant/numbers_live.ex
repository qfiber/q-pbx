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

      <p :if={@dids == []} id="no-numbers">{gettext("No numbers yet.")}</p>

      <div :for={did <- @dids} class="card bg-base-200 p-4" id={"number-#{did.id}"}>
        <p class="font-semibold"><span dir="ltr">{Numbers.display(did.number, @rule)}</span></p>
        <p :if={did.alias_of_id} class="text-sm">
          {gettext(
            "Backup number: calls to it go where its main number goes. Ask the main number's carrier to forward to it when this PBX does not answer."
          )}
        </p>
        <.form
          :if={!did.alias_of_id}
          for={@forms[did.id]}
          phx-submit="save"
          phx-value-id={did.id}
          id={"did-form-#{did.id}"}
        >
          <div class="grid sm:grid-cols-3 gap-2 items-end">
            <.input
              field={@forms[did.id][:destination_type]}
              type="select"
              label={gettext("Calls go to")}
              options={[
                {gettext("Nowhere (rejected)"), ""},
                {gettext("An extension"), "extension"},
                {gettext("An outside number"), "external"}
              ]}
            />
            <.input
              field={@forms[did.id][:destination_id]}
              type="select"
              label={gettext("Extension")}
              options={[{"—", ""} | Enum.map(@extensions, &{"#{&1.number} #{&1.name}", &1.id})]}
            />
            <.input
              field={@forms[did.id][:destination_number]}
              label={gettext("Outside number")}
              dir="ltr"
            />
          </div>
          <.button variant="primary">{gettext("Save")}</.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
