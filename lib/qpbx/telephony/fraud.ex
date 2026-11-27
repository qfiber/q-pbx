defmodule QPBX.Telephony.Fraud do
  @moduledoc """
  Velocity rules. Every international (or premium) attempt is noted per tenant in memory; more
  than `international_spike_calls` within 10 minutes is a spike, and an international call in
  the tenant's quiet hours is suspicious. Each raises a `FraudAlert` (audited) at most once
  per hour per tenant and rule, and, when the settings say so, blocks the tenant's
  international and premium calls for `block_hours` (`fraud_blocks`; platform admins can lift
  it). Emergency calls are never affected.
  """
  use GenServer
  import Ecto.Query
  require Logger
  alias QPBX.Events
  alias QPBX.Events.FraudAlert
  alias QPBX.Repo

  @window_s 600
  @table __MODULE__
  @actor {:system, "fraud"}

  defmodule Settings do
    @moduledoc "Velocity rule settings (one row)."
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :boolean, autogenerate: false}
    schema "fraud_settings" do
      field :international_spike_calls, :integer
      field :block_on_spike, :boolean
      field :quiet_start_hour, :integer
      field :quiet_end_hour, :integer
      field :block_in_quiet_hours, :boolean
      field :block_hours, :integer
      timestamps(type: :utc_datetime)
    end

    @fields ~w(international_spike_calls block_on_spike quiet_start_hour quiet_end_hour block_in_quiet_hours block_hours)a

    def changeset(s, attrs) do
      s
      |> cast(attrs, @fields)
      |> validate_required(@fields)
      |> validate_number(:international_spike_calls,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: 10_000
      )
      |> validate_number(:quiet_start_hour,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 23
      )
      |> validate_number(:quiet_end_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
      |> validate_number(:block_hours, greater_than_or_equal_to: 1, less_than_or_equal_to: 720)
    end
  end

  defmodule Block do
    @moduledoc "A tenant's international and premium calls blocked until `until`."
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id
    schema "fraud_blocks" do
      field :tenant_id, :binary_id
      field :reason, :string
      field :until, :utc_datetime
      timestamps(type: :utc_datetime)
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## Settings and blocks (platform admins)

  def settings, do: Repo.get!(Settings, true)
  def change_settings(s, attrs \\ %{}), do: Settings.changeset(s, attrs)

  def update_settings(attrs, actor) do
    cs = Settings.changeset(settings(), attrs)

    Repo.transaction(fn ->
      with {:ok, s} <- Repo.update(cs),
           {:ok, _} <- QPBX.Core.audit(actor, "fraud_settings.update", nil, cs.changes) do
        s
      else
        {:error, e} -> Repo.rollback(e)
      end
    end)
  end

  def list_blocks(now \\ DateTime.utc_now()),
    do: Repo.all(from b in Block, where: b.until > ^now, order_by: [desc: b.inserted_at])

  def blocked?(tenant_id, now \\ DateTime.utc_now()),
    do: Repo.exists?(from b in Block, where: b.tenant_id == ^tenant_id and b.until > ^now)

  def lift(id, actor) do
    with %Block{} = b <- Repo.get(Block, id) do
      Repo.delete!(b)
      # A fresh start: the attempts that caused the block would otherwise block again at once.
      :ets.delete(@table, {:attempt, b.tenant_id})
      QPBX.Core.audit(actor, "fraud_block.lift", nil, %{tenant_id: b.tenant_id, reason: b.reason})
    end

    :ok
  end

  ## Velocity

  @doc """
  Notes an international or premium attempt and applies the rules. Returns `:ok`, or
  `{:blocked, reason}` when a rule just blocked the tenant.
  """
  def international_attempt(tenant_id, timezone, now \\ DateTime.utc_now()) do
    s = settings()
    ts = DateTime.to_unix(now)
    :ets.insert(@table, {{:attempt, tenant_id}, ts})

    :ets.select_delete(@table, [
      {{{:attempt, tenant_id}, :"$1"}, [{:<, :"$1", ts - @window_s}], [true]}
    ])

    count = length(:ets.lookup(@table, {:attempt, tenant_id}))

    cond do
      count > s.international_spike_calls ->
        fire(
          tenant_id,
          "international_spike",
          "#{count} international calls in 10 minutes",
          s.block_on_spike,
          s,
          now
        )

      quiet_hour?(now, timezone, s) ->
        fire(
          tenant_id,
          "quiet_hours",
          "international call at #{local_time(now, timezone)}",
          s.block_in_quiet_hours,
          s,
          now
        )

      true ->
        :ok
    end
  end

  @doc false
  def quiet_hour?(now, timezone, %{quiet_start_hour: a, quiet_end_hour: b}) do
    h = local(now, timezone).hour
    if a <= b, do: h >= a and h < b, else: h >= a or h < b
  end

  defp fire(tenant_id, rule, detail, block?, s, now) do
    # One alert per tenant and rule per hour.
    key = {:alerted, tenant_id, rule}
    last = :ets.lookup(@table, key) |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> nil end)

    if is_nil(last) or last < DateTime.to_unix(now) - 3600 do
      :ets.delete(@table, key)
      :ets.insert(@table, {key, DateTime.to_unix(now)})

      Logger.warning(
        "fraud: #{rule} for tenant #{tenant_id}: #{detail}#{if block?, do: " (blocked)", else: ""}"
      )

      QPBX.Core.audit(@actor, "fraud.#{rule}", nil, %{
        tenant_id: tenant_id,
        detail: detail,
        blocked: block?
      })

      Events.publish(%FraudAlert{
        tenant_id: tenant_id,
        rule: rule,
        detail: detail,
        blocked: block?,
        at: now
      })
    end

    if block? do
      if not blocked?(tenant_id, now) do
        until = now |> DateTime.add(s.block_hours * 3600) |> DateTime.truncate(:second)
        Repo.insert!(%Block{tenant_id: tenant_id, reason: rule, until: until})
      end

      {:blocked, rule}
    else
      :ok
    end
  end

  defp local(now, timezone) do
    case DateTime.shift_zone(now, timezone) do
      {:ok, l} -> l
      _ -> now
    end
  end

  defp local_time(now, timezone),
    do: now |> local(timezone) |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_string()

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :duplicate_bag])
    {:ok, nil}
  end
end
