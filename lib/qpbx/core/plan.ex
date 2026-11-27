defmodule QPBX.Core.Plan do
  @moduledoc "A named set of limits. A nil limit means unlimited."
  use Ecto.Schema
  import Ecto.Changeset

  @destination_classes ~w(local mobile international premium)
  @periods ~w(hour day month)
  # Outbound minutes per destination class and period (call admission).
  @class_minutes for c <- @destination_classes, p <- @periods, do: :"minutes_#{c}_per_#{p}"
  # Built at compile time: no atoms are made from data at run time.
  @class_minutes_by_key for c <- @destination_classes,
                            p <- @periods,
                            into: %{},
                            do: {{c, p}, :"minutes_#{c}_per_#{p}"}
  @limits ~w(max_extensions max_concurrent_calls_inbound max_concurrent_calls_outbound
             max_concurrent_calls_total max_concurrent_calls_per_extension max_queues max_ivrs
             max_conferences recording_storage_gb fax_storage_gb outbound_minutes_per_day
             outbound_minutes_per_month api_rate_limit_per_minute)a ++ @class_minutes
  @features ~w(fax crm flow_builder recording)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "plans" do
    field :name, :string
    for limit <- @limits, do: field(limit, :integer)
    field :allowed_destination_classes, {:array, :string}, default: []
    field :features, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  @doc "Integer limit fields. Tenants may override any of these."
  def limits, do: @limits
  def destination_classes, do: @destination_classes
  def periods, do: @periods

  @doc "The limit holding outbound minutes for a destination class and period."
  def class_minutes_limit(class, period), do: Map.fetch!(@class_minutes_by_key, {class, period})

  def features, do: @features

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [:name, :allowed_destination_classes, :features | @limits])
    |> validate_required([:name])
    |> validate_length(:name, max: 100)
    |> then(fn cs ->
      Enum.reduce(@limits, cs, &validate_number(&2, &1, greater_than_or_equal_to: 0))
    end)
    |> validate_subset(:allowed_destination_classes, @destination_classes)
    |> validate_change(:features, &validate_features/2)
    |> unique_constraint(:name)
  end

  defp validate_features(:features, features) do
    Enum.flat_map(features, fn {k, v} ->
      cond do
        to_string(k) not in @features -> [features: "unknown feature #{k}"]
        not is_boolean(v) -> [features: "#{k} must be true or false"]
        true -> []
      end
    end)
  end
end
