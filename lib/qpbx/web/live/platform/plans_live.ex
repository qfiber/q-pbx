defmodule QPBX.Web.Platform.PlansLive do
  @moduledoc "Platform admin: list plans and create one."
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Core.Plan

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Plans"),
       plans: Core.list_plans(),
       form: to_form(Core.change_plan())
     )}
  end

  @impl true
  def handle_event("validate", %{"plan" => params}, socket) do
    cs = Core.change_plan(%Core.Plan{}, plan_params(params)) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("save", %{"plan" => params}, socket) do
    params = plan_params(params)

    case Core.create_plan(params, socket.assigns.current_account) do
      {:ok, plan} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Plan %{name} created.", name: plan.name))
         |> assign(plans: Core.list_plans(), form: to_form(Core.change_plan()))}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :insert)))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      locale={@locale}
      current_account={@current_account}
      idle_timeout={@idle_timeout}
    >
      <.header>{gettext("Plans")}</.header>

      <.table id="plans" rows={@plans}>
        <:col :let={p} label={gettext("Name")}>{p.name}</:col>
        <:col :let={p} label={limit_label(:max_extensions)}>
          {p.max_extensions || gettext("Unlimited")}
        </:col>
        <:col :let={p} label={limit_label(:max_concurrent_calls_total)}>
          {p.max_concurrent_calls_total || gettext("Unlimited")}
        </:col>
      </.table>

      <h2 class="text-lg font-semibold mt-8">{gettext("New plan")}</h2>
      <p class="text-sm opacity-70">{gettext("Leave a limit empty for unlimited.")}</p>
      <.form for={@form} id="plan-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} label={gettext("Name")} required />
        <div class="grid sm:grid-cols-2 gap-x-4">
          <.input
            :for={limit <- Plan.limits()}
            field={@form[limit]}
            type="number"
            min="0"
            label={limit_label(limit)}
          />
        </div>
        <.input
          field={@form[:allowed_destination_classes]}
          type="select"
          multiple
          label={gettext("Allowed destination classes")}
          options={Enum.map(Plan.destination_classes(), &{class_label(&1), &1})}
        />
        <fieldset class="fieldset mb-2">
          <legend class="fieldset-legend">{gettext("Features")}</legend>
          <.input
            :for={f <- Plan.features()}
            name={"plan[feature_#{f}]"}
            type="checkbox"
            label={feature_label(f)}
            value={false}
          />
        </fieldset>
        <.button variant="primary">{gettext("Create plan")}</.button>
      </.form>
    </Layouts.app>
    """
  end

  defp plan_params(params) do
    params
    |> Map.update("allowed_destination_classes", [], &Enum.reject(&1, fn v -> v == "" end))
    |> Map.put("features", Map.new(Plan.features(), &{&1, params["feature_" <> &1] == "true"}))
  end

  defp limit_label(:max_extensions), do: gettext("Max extensions")
  defp limit_label(:max_concurrent_calls_inbound), do: gettext("Max concurrent inbound calls")
  defp limit_label(:max_concurrent_calls_outbound), do: gettext("Max concurrent outbound calls")
  defp limit_label(:max_concurrent_calls_total), do: gettext("Max concurrent calls")
  defp limit_label(:max_queues), do: gettext("Max queues")
  defp limit_label(:max_ivrs), do: gettext("Max IVRs")
  defp limit_label(:max_conferences), do: gettext("Max conferences")
  defp limit_label(:recording_storage_gb), do: gettext("Recording storage (GB)")
  defp limit_label(:fax_storage_gb), do: gettext("Fax storage (GB)")
  defp limit_label(:outbound_minutes_per_day), do: gettext("Outbound minutes per day")
  defp limit_label(:outbound_minutes_per_month), do: gettext("Outbound minutes per month")
  defp limit_label(:api_rate_limit_per_minute), do: gettext("API requests per minute")

  defp limit_label(:max_concurrent_calls_per_extension),
    do: gettext("Max concurrent calls per extension")

  defp limit_label(limit) do
    ["minutes", class, "per", period] = limit |> Atom.to_string() |> String.split("_")

    gettext("%{class} minutes per %{period}",
      class: class_label(class),
      period: period_label(period)
    )
  end

  defp period_label("hour"), do: gettext("hour")
  defp period_label("day"), do: gettext("day")
  defp period_label("month"), do: gettext("month")

  defp class_label("local"), do: gettext("Local")
  defp class_label("mobile"), do: gettext("Mobile")
  defp class_label("international"), do: gettext("International")
  defp class_label("premium"), do: gettext("Premium")

  defp feature_label("fax"), do: gettext("Fax")
  defp feature_label("crm"), do: gettext("CRM")
  defp feature_label("flow_builder"), do: gettext("Flow builder")
  defp feature_label("recording"), do: gettext("Recording")
end
