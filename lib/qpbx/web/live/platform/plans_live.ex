defmodule QPBX.Web.Platform.PlansLive do
  @moduledoc """
  Platform admin: list plans, create one, or edit one (`/platform/plans/:id`). An edit applies
  to every tenant on the plan at once (their own overrides still win).
  """
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Core.Plan
  alias QPBX.Web.{Pager, PlanFields}

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Plans"), plans: Core.list_plans())}

  @impl true
  def handle_params(params, uri, socket) do
    socket |> assign(page: params["page"]) |> plan_params_for(params, uri)
  end

  defp plan_params_for(socket, %{"id" => id}, _uri) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:noreply, editing(socket, Core.get_plan!(id))}
      :error -> {:noreply, push_navigate(socket, to: ~p"/platform/plans")}
    end
  end

  defp plan_params_for(socket, _params, _uri), do: {:noreply, editing(socket, %Plan{})}

  defp editing(socket, plan),
    do: assign(socket, plan: plan, form: to_form(Core.change_plan(plan)))

  @impl true
  def handle_event("validate", %{"plan" => params}, socket) do
    cs = Core.change_plan(socket.assigns.plan, plan_params(params)) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("save", %{"plan" => params}, socket) do
    %{plan: plan, current_account: actor} = socket.assigns
    params = plan_params(params)

    result =
      if plan.id, do: Core.update_plan(plan, params, actor), else: Core.create_plan(params, actor)

    case result do
      {:ok, saved} ->
        msg =
          if plan.id,
            do: gettext("Plan %{name} saved.", name: saved.name),
            else: gettext("Plan %{name} created.", name: saved.name)

        plans = Core.list_plans()

        {:noreply,
         socket
         |> put_flash(:info, msg)
         |> assign(plans: plans)
         |> push_patch(to: ~p"/platform/plans?page=#{Pager.page_of(plans, saved.id)}")}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :validate)))}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        on_plan: Enum.frequencies_by(Core.list_tenants(), & &1.plan_id),
        paged: Pager.paginate(assigns.plans, assigns.page)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      locale={@locale}
      current_account={@current_account}
      unread={assigns[:unread]}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("Plans")}
        <:subtitle>
          {gettext("What a tenant may use. A tenant's own overrides win over its plan.")}
        </:subtitle>
        <:actions>
          <.link :if={@plan.id} patch={~p"/platform/plans"} class="btn btn-primary" id="new-plan">
            <.icon name="hero-plus" class="size-4" /> {gettext("New plan")}
          </.link>
        </:actions>
      </.header>

      <.table
        id="plans"
        rows={@paged.items}
        row_click={&JS.patch(~p"/platform/plans/#{&1.id}")}
      >
        <:col :let={p} label={gettext("Plan")}>
          <span class="font-semibold">{p.name}</span>
          <span class="block text-xs text-muted">
            {ngettext("1 tenant", "%{count} tenants", Map.get(@on_plan, p.id, 0))}
          </span>
        </:col>
        <:col :let={p} label={gettext("Extensions")}>{limit_value(p.max_extensions)}</:col>
        <:col :let={p} label={gettext("Calls at once")}>
          {limit_value(p.max_concurrent_calls_total)}
        </:col>
        <:col :let={p} label={gettext("Minutes a month")}>
          {limit_value(p.outbound_minutes_per_month)}
        </:col>
        <:col :let={p} label={gettext("Destinations")}>
          <div class="flex flex-wrap gap-1">
            <span
              :for={c <- p.allowed_destination_classes}
              class="rounded-[6px] bg-accent-pale text-secondary px-1.5 py-0.5 text-xs"
            >
              {class_label(c)}
            </span>
          </div>
        </:col>
        <:col :let={p} label={gettext("Features")}>
          <div class="flex flex-wrap gap-1">
            <span
              :for={{f, true} <- Enum.sort(p.features || %{})}
              class="rounded-[6px] bg-warm-pale text-warm-ink px-1.5 py-0.5 text-xs"
            >
              {feature_label(to_string(f))}
            </span>
          </div>
        </:col>
        <:action :let={p}>
          <.link
            patch={~p"/platform/plans/#{p.id}"}
            id={"edit-plan-#{p.id}"}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-pencil-square" class="size-4" /> {gettext("Edit")}
          </.link>
        </:action>
      </.table>

      <Pager.pager id="plans-pages" page={@paged} to={&page_path(@plan, &1)} />

      <h2 id="plan-form-title">
        {if @plan.id, do: gettext("Edit plan %{name}", name: @plan.name), else: gettext("New plan")}
      </h2>
      <.form for={@form} id="plan-form" phx-change="validate" phx-submit="save">
        <div class="divide-y divide-base-300">
          <PlanFields.section
            title={gettext("Plan")}
            icon="hero-rectangle-stack"
            hint={
              if @plan.id,
                do:
                  gettext(
                    "Changes apply at once to every tenant on this plan; a tenant's own overrides still win."
                  ),
                else: gettext("Leave a limit empty for unlimited.")
            }
          >
            <div class="max-w-md">
              <.input field={@form[:name]} label={gettext("Name")} required />
            </div>
          </PlanFields.section>

          <PlanFields.limits
            hint={gettext("Leave a limit empty for unlimited.")}
            input={fn l -> %{field: @form[l]} end}
          />

          <PlanFields.section
            title={gettext("Destinations and features")}
            icon="hero-sparkles"
            hint={gettext("Where tenants on this plan may call, and what they get.")}
          >
            <div class="grid sm:grid-cols-2 gap-6">
              <fieldset>
                <legend class="text-sm font-medium mb-2">
                  {gettext("Allowed destination classes")}
                </legend>
                <input type="hidden" name="plan[allowed_destination_classes][]" value="" />
                <label
                  :for={c <- Plan.destination_classes()}
                  class="flex items-center gap-2 py-1 text-sm cursor-pointer"
                >
                  <input
                    type="checkbox"
                    name="plan[allowed_destination_classes][]"
                    value={c}
                    checked={
                      c in (Ecto.Changeset.get_field(@form.source, :allowed_destination_classes) || [])
                    }
                    class="checkbox checkbox-sm checkbox-primary"
                  />
                  {class_label(c)}
                </label>
              </fieldset>
              <fieldset>
                <legend class="text-sm font-medium mb-2">{gettext("Features")}</legend>
                <.input
                  :for={f <- Plan.features()}
                  name={"plan[feature_#{f}]"}
                  type="checkbox"
                  label={feature_label(f)}
                  value={feature_on?(@form, f)}
                />
              </fieldset>
            </div>
            <div class="max-w-md mt-2">
              <.input
                name="plan[usage_thresholds]"
                id="plan_usage_thresholds"
                value={percents_text(Ecto.Changeset.get_field(@form.source, :usage_thresholds))}
                label={gettext("Usage alerts at (% of the monthly outbound minutes)")}
                placeholder="50, 80, 90, 100"
                dir="ltr"
                errors={Enum.map(@form[:usage_thresholds].errors, &translate_error/1)}
              />
            </div>
          </PlanFields.section>
        </div>
        <div class="flex flex-wrap gap-2 pt-5 mt-2 border-t border-base-300">
          <.button variant="primary">
            {if @plan.id, do: gettext("Save plan"), else: gettext("Create plan")}
          </.button>
          <.link :if={@plan.id} patch={~p"/platform/plans"} class="btn btn-ghost">
            {gettext("Cancel")}
          </.link>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  defp page_path(%Plan{id: nil}, n), do: ~p"/platform/plans?page=#{n}"
  defp page_path(%Plan{id: id}, n), do: ~p"/platform/plans/#{id}?page=#{n}"

  defp limit_value(nil), do: gettext("Unlimited")
  defp limit_value(n), do: n

  defp feature_on?(form, f) do
    features = Ecto.Changeset.get_field(form.source, :features) || %{}
    Enum.any?(features, fn {k, v} -> to_string(k) == f and v == true end)
  end

  @doc "\"50, 80\" to [50, 80]; anything not a whole number is kept, for the changeset to refuse."
  def parse_percents(nil), do: nil
  def parse_percents(""), do: nil

  def parse_percents(text) when is_binary(text) do
    for part <- String.split(text, [",", " ", ";"], trim: true) do
      case Integer.parse(part) do
        {n, ""} -> n
        _ -> part
      end
    end
  end

  def parse_percents(list), do: list

  def percents_text(nil), do: ""
  def percents_text(list) when is_list(list), do: Enum.map_join(list, ", ", &to_string/1)
  def percents_text(other), do: to_string(other)

  defp plan_params(params) do
    params
    |> Map.update("usage_thresholds", nil, &(parse_percents(&1) || []))
    |> Map.update("allowed_destination_classes", [], &Enum.reject(&1, fn v -> v == "" end))
    |> Map.put("features", Map.new(Plan.features(), &{&1, params["feature_" <> &1] == "true"}))
  end

  @doc false
  def limit_label(:max_extensions), do: gettext("Max extensions")
  def limit_label(:max_concurrent_calls_inbound), do: gettext("Max concurrent inbound calls")
  def limit_label(:max_concurrent_calls_outbound), do: gettext("Max concurrent outbound calls")
  def limit_label(:max_concurrent_calls_total), do: gettext("Max concurrent calls")
  def limit_label(:max_queues), do: gettext("Max queues")
  def limit_label(:max_ivrs), do: gettext("Max IVRs")
  def limit_label(:max_conferences), do: gettext("Max conferences")
  def limit_label(:recording_storage_gb), do: gettext("Recording storage (GB)")
  def limit_label(:fax_storage_gb), do: gettext("Fax storage (GB)")
  def limit_label(:outbound_minutes_per_day), do: gettext("Outbound minutes per day")
  def limit_label(:outbound_minutes_per_month), do: gettext("Outbound minutes per month")
  def limit_label(:api_rate_limit_per_minute), do: gettext("API requests per minute")

  def limit_label(:max_concurrent_calls_per_extension),
    do: gettext("Max concurrent calls per extension")

  def limit_label(limit) do
    ["minutes", class, "per", period] = limit |> Atom.to_string() |> String.split("_")

    gettext("%{class} minutes per %{period}",
      class: class_label(class),
      period: period_label(period)
    )
  end

  @doc false
  def period_title("hour"), do: gettext("Per hour")
  def period_title("day"), do: gettext("Per day")
  def period_title("month"), do: gettext("Per month")

  defp period_label("hour"), do: gettext("hour")
  defp period_label("day"), do: gettext("day")
  defp period_label("month"), do: gettext("month")

  @doc false
  def class_label("local"), do: gettext("Local")
  def class_label("mobile"), do: gettext("Mobile")
  def class_label("international"), do: gettext("International")
  def class_label("premium"), do: gettext("Premium")

  defp feature_label("fax"), do: gettext("Fax")
  defp feature_label("crm"), do: gettext("CRM")
  defp feature_label("flow_builder"), do: gettext("Flow builder")
  defp feature_label("recording"), do: gettext("Recording")
end
