defmodule QPBX.Telephony.Usage do
  @moduledoc """
  Outbound talk time per tenant, destination class and hour (`call_usage`). Call admission
  compares it with the plan's minute caps; days and months are sums of hours, counted in the
  tenant's time zone (hour buckets are UTC hours).
  """
  use Ecto.Schema
  import Ecto.Query
  alias QPBX.Repo

  @primary_key false
  schema "call_usage" do
    field :tenant_id, :binary_id, primary_key: true
    field :class, :string, primary_key: true
    field :hour, :utc_datetime, primary_key: true
    field :seconds, :integer, default: 0
  end

  @doc "Adds the seconds of a finished call to its hour."
  def add(_tenant_id, _class, seconds, _at) when seconds <= 0, do: :ok

  def add(tenant_id, class, seconds, %DateTime{} = at) do
    hour = %{DateTime.truncate(at, :second) | minute: 0, second: 0}

    Repo.insert!(%__MODULE__{tenant_id: tenant_id, class: class, hour: hour, seconds: seconds},
      on_conflict: [inc: [seconds: seconds]],
      conflict_target: [:tenant_id, :class, :hour]
    )

    :ok
  end

  @doc """
  Seconds used this hour, today and this month (in `timezone`), per class:
  `%{"international" => %{hour: s, day: s, month: s}, ...}`.
  """
  def used(tenant_id, timezone, now \\ DateTime.utc_now()) do
    {hour, day, month} = starts(now, timezone)

    Repo.all(
      from u in __MODULE__,
        where: u.tenant_id == ^tenant_id and u.hour >= ^month,
        group_by: u.class,
        select:
          {u.class,
           %{
             hour: sum(fragment("CASE WHEN ? >= ? THEN ? ELSE 0 END", u.hour, ^hour, u.seconds)),
             day: sum(fragment("CASE WHEN ? >= ? THEN ? ELSE 0 END", u.hour, ^day, u.seconds)),
             month: sum(u.seconds)
           }}
    )
    |> Map.new()
  end

  defp starts(now, timezone) do
    hour = %{DateTime.truncate(now, :second) | minute: 0, second: 0}

    local =
      case DateTime.shift_zone(now, timezone) do
        {:ok, l} -> l
        _ -> now
      end

    day = local |> DateTime.to_date() |> midnight(timezone)
    month = local |> DateTime.to_date() |> Date.beginning_of_month() |> midnight(timezone)
    {hour, day, month}
  end

  defp midnight(date, timezone) do
    case DateTime.new(date, ~T[00:00:00], timezone) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:gap, _, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
      {:ambiguous, first, _} -> DateTime.shift_zone!(first, "Etc/UTC")
      _ -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end
end
