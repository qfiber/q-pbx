defmodule QPBX.Web.Platform.FraudLive do
  @moduledoc """
  Platform admin: velocity rules (international spikes, quiet hours) and the tenants whose
  international and premium calls they blocked, which can be lifted. Limits per plan (classes,
  concurrent calls, minutes) are on the plans page.
  """
  use QPBX.Web, :live_view
  alias QPBX.{Core, Telephony}

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(page_title: gettext("Fraud protection")) |> load()}

  defp load(socket) do
    s = Telephony.fraud_settings()
    names = Map.new(Core.list_tenants(), &{&1.id, &1.name})

    assign(socket,
      settings: s,
      form: to_form(Telephony.change_fraud_settings(s)),
      blocks: Telephony.list_fraud_blocks(),
      names: names
    )
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    case Telephony.update_fraud_settings(params, socket.assigns.current_account) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}
      {:error, cs} -> {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :update)))}
    end
  end

  def handle_event("lift", %{"id" => id}, socket) do
    :ok = Telephony.lift_fraud_block(id, socket.assigns.current_account)
    {:noreply, socket |> put_flash(:info, gettext("Block lifted.")) |> load()}
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
        {gettext("Fraud protection")}
        <:subtitle>
          {gettext(
            "Velocity rules for international and premium calls. A rule raises an alert, and can block the tenant's international and premium calls. Emergency calls are never blocked."
          )}
        </:subtitle>
      </.header>

      <.form for={@form} id="fraud-form" phx-submit="save">
        <div class="divide-y divide-base-300">
          <.section title={gettext("Spikes")} icon="hero-arrow-trending-up">
            <div class="grid sm:grid-cols-2 gap-x-4">
              <.input
                field={@form[:international_spike_calls]}
                type="number"
                min="1"
                label={gettext("International calls in 10 minutes that count as a spike")}
              />
              <.input
                field={@form[:block_hours]}
                type="number"
                min="1"
                label={gettext("Block length (hours)")}
              />
            </div>
            <.input
              field={@form[:block_on_spike]}
              type="checkbox"
              label={gettext("Block on a spike")}
            />
          </.section>
          <.section title={gettext("Quiet hours")} icon="hero-moon">
            <div class="grid sm:grid-cols-2 gap-x-4">
              <.input
                field={@form[:quiet_start_hour]}
                type="number"
                min="0"
                max="23"
                label={gettext("Quiet hours start (tenant's time zone, 0-23)")}
              />
              <.input
                field={@form[:quiet_end_hour]}
                type="number"
                min="0"
                max="23"
                label={gettext("Quiet hours end (0-23)")}
              />
            </div>
            <.input
              field={@form[:block_in_quiet_hours]}
              type="checkbox"
              label={gettext("Block international calls in quiet hours")}
            />
          </.section>
        </div>
        <.form_actions><.button variant="primary">{gettext("Save")}</.button></.form_actions>
      </.form>

      <.section title={gettext("Blocked tenants")} icon="hero-shield-exclamation">
        <.live_component
          module={PagedTable}
          id="fraud-blocks"
          rows={@blocks}
          empty={gettext("No tenant is blocked.")}
        >
          <:col :let={b} label={gettext("Tenant")}>
            <span class="font-medium">{@names[b.tenant_id] || b.tenant_id}</span>
          </:col>
          <:col :let={b} label={gettext("Reason")}>
            <.chip tone={:danger}>{rule_label(b.reason)}</.chip>
          </:col>
          <:col :let={b} label={gettext("Until (UTC)")}>
            <span class="text-muted">{b.until}</span>
          </:col>
          <:action :let={b}>
            <.link
              phx-click="lift"
              phx-value-id={b.id}
              id={"lift-#{b.id}"}
              class="btn btn-ghost btn-xs"
              data-confirm={
                gettext("Lift the block of %{tenant}?", tenant: @names[b.tenant_id] || "")
              }
            >
              <.icon name="hero-lock-open" class="size-4" /> {gettext("Lift")}
            </.link>
          </:action>
        </.live_component>
      </.section>
    </Layouts.app>
    """
  end

  defp rule_label("international_spike"), do: gettext("International spike")
  defp rule_label("quiet_hours"), do: gettext("Quiet hours")
  defp rule_label(other), do: other
end
