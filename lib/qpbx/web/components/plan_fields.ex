defmodule QPBX.Web.PlanFields do
  @moduledoc """
  The limits of a plan (or a tenant's overrides) in groups people think in: accounts, calls
  at the same time, outbound minutes, minutes per destination class (a grid: class by
  period), storage, API. `limits/1` renders them with the page's own input attributes;
  the sections and groups are `QPBX.Web.UI`'s.
  """
  use Phoenix.Component
  use Gettext, backend: QPBX.Web.Gettext
  import QPBX.Web.CoreComponents, only: [input: 1]
  import QPBX.Web.UI, only: [section: 1, field_group: 1]
  alias QPBX.Core.Plan
  alias QPBX.Web.Platform.PlansLive

  @groups [
    {:accounts, "hero-users", ~w(max_extensions max_queues max_ivrs max_conferences)a},
    {:calls, "hero-phone",
     ~w(max_concurrent_calls_total max_concurrent_calls_inbound max_concurrent_calls_outbound
        max_concurrent_calls_per_extension)a},
    {:minutes, "hero-clock", ~w(outbound_minutes_per_day outbound_minutes_per_month)a},
    {:storage, "hero-circle-stack", ~w(recording_storage_gb fax_storage_gb)a},
    {:api, "hero-code-bracket", ~w(api_rate_limit_per_minute)a}
  ]

  @doc "Every limit in the groups and the class grid (a test checks none is missing)."
  def grouped do
    for({_, _, ls} <- @groups, l <- ls, do: l) ++
      for c <- Plan.destination_classes(), p <- Plan.periods(), do: Plan.class_minutes_limit(c, p)
  end

  defp title(:accounts), do: gettext("Accounts")
  defp title(:calls), do: gettext("Calls at the same time")
  defp title(:minutes), do: gettext("Outbound minutes")
  defp title(:storage), do: gettext("Storage")
  defp title(:api), do: gettext("API")

  attr :input, :any, required: true, doc: "limit -> input attributes (field, or name/value/...)"
  attr :hint, :string, default: nil

  @doc "The limits as one section, its groups inside."
  def limits(assigns) do
    assigns = assign(assigns, groups: @groups)

    ~H"""
    <.section title={gettext("Limits")} icon="hero-adjustments-horizontal" hint={@hint}>
      <div class="space-y-1">
        <.field_group :for={{key, icon, ls} <- @groups} title={title(key)} icon={icon}>
          <div class="grid sm:grid-cols-2 lg:grid-cols-4 gap-x-4">
            <.input
              :for={l <- ls}
              type="number"
              min="0"
              label={PlansLive.limit_label(l)}
              {@input.(l)}
            />
          </div>
        </.field_group>
        <.field_group
          title={gettext("Minutes by destination")}
          icon="hero-globe-alt"
          hint={gettext("Outbound minutes for each kind of number, per hour, day and month.")}
        >
          <div class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead>
                <tr class="text-muted">
                  <th class="text-start font-medium pb-1"></th>
                  <th :for={p <- Plan.periods()} class="text-start font-medium pb-1 px-1">
                    {PlansLive.period_title(p)}
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={c <- Plan.destination_classes()}>
                  <th class="text-start font-medium pe-3 whitespace-nowrap">
                    {PlansLive.class_label(c)}
                  </th>
                  <td :for={p <- Plan.periods()} class="px-1 min-w-28">
                    <.input
                      type="number"
                      min="0"
                      aria-label={PlansLive.limit_label(Plan.class_minutes_limit(c, p))}
                      {@input.(Plan.class_minutes_limit(c, p))}
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.field_group>
      </div>
    </.section>
    """
  end
end
