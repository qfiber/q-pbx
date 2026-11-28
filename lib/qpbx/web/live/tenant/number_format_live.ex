defmodule QPBX.Web.Tenant.NumberFormatLive do
  @moduledoc "Tenant admin: how the tenant's people dial and see numbers."
  use QPBX.Web, :live_view
  alias QPBX.Core

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(page_title: gettext("Number format")) |> load()}

  defp load(socket) do
    rule = Core.number_rule(socket.assigns.current_scope)

    assign(socket,
      rule: rule,
      own?: rule.tenant_id != nil,
      form: rule_form(Core.change_number_rule(rule))
    )
  end

  defp rule_form(cs) do
    intl = Ecto.Changeset.get_field(cs, :international_prefixes) || []

    cs
    |> to_form(as: :rule)
    |> Map.update!(:params, &Map.put_new(&1, "international_text", Enum.join(intl, ", ")))
  end

  @impl true
  def handle_event("save", %{"rule" => params}, socket) do
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
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}
      {:error, cs} -> {:noreply, assign(socket, form: rule_form(Map.put(cs, :action, :update)))}
    end
  end

  def handle_event("reset", _, socket) do
    {:ok, _} =
      Core.reset_number_rule(socket.assigns.current_scope, socket.assigns.current_account)

    {:noreply, socket |> put_flash(:info, gettext("Back to the platform's default.")) |> load()}
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
        {gettext("Number format")}
        <:subtitle>
          {if @own?,
            do: gettext("Your own settings."),
            else: gettext("The platform's default. Saving makes your own copy.")}
        </:subtitle>
      </.header>
      <.form for={@form} id="number-format-form" phx-submit="save">
        <.section
          title={gettext("How your numbers are written")}
          icon="hero-hashtag"
          hint={gettext("Used to read numbers typed the local way, like 02-123-4567.")}
        >
          <div class="grid sm:grid-cols-2 gap-x-4">
            <.input
              field={@form[:country_code]}
              label={gettext("Country code (e.g. 972)")}
              dir="ltr"
              required
            />
            <.input
              field={@form[:national_prefix]}
              label={gettext("National prefix (e.g. 0)")}
              dir="ltr"
            />
            <.input
              name="rule[international_text]"
              id="rule_international_text"
              value={@form.params["international_text"]}
              label={gettext("International prefixes, comma-separated (e.g. 00, 012, 013)")}
              dir="ltr"
              errors={Enum.map(@form[:international_prefixes].errors, &translate_error/1)}
            />
            <.input
              field={@form[:area_code]}
              label={gettext("Area code for short local numbers (optional, e.g. 2)")}
              dir="ltr"
            />
          </div>
        </.section>
        <.form_actions>
          <.button variant="primary">{gettext("Save")}</.button>
          <.button
            :if={@own?}
            type="button"
            phx-click="reset"
            id="reset-format"
            class="btn btn-ghost"
            data-confirm={gettext("Go back to the platform's default?")}
          >
            {gettext("Use the platform default")}
          </.button>
        </.form_actions>
      </.form>
    </Layouts.app>
    """
  end
end
