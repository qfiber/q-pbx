defmodule QPBX.Web.Health do
  @moduledoc """
  Runs the health checks every 10 seconds in the background and caches the result in ETS,
  so `/health` is cheap to scrape. Each check runs in its own task with a timeout, so one
  hanging component cannot stall the others.

  Overall status: `down` if a critical component (PostgreSQL, FreeSWITCH, Kamailio) is in
  error, `degraded` if anything else is in warning or error, otherwise `ok`. Components that
  are `not_configured` do not count.
  """
  use GenServer
  alias QPBX.Web.Health.Checks

  @table __MODULE__
  @critical [:postgres, :freeswitch, :kamailio]
  @components [
    :postgres,
    :freeswitch,
    :kamailio,
    :disk,
    :trunk_registrations,
    :oban_backlog,
    :certificate,
    :backups
  ]
  @check_timeout 3_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The cached `%{status: ..., components: ..., checked_at: ...}`, or a `down` result before the first run."
  def current do
    case :ets.whereis(@table) != :undefined && :ets.lookup(@table, :result) do
      [{:result, result}] -> result
      _ -> %{status: "down", components: %{}, checked_at: nil}
    end
  end

  @doc "Replaces the cached result (tests and manual overrides)."
  def put(result), do: GenServer.call(__MODULE__, {:put, result})

  @doc "Runs every check now and returns the result (used by tests and on start)."
  def run(config \\ config()) do
    components =
      @components
      |> Task.async_stream(&{&1, apply(Checks, &1, [Keyword.get(config, &1, [])])},
        timeout: @check_timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(@components)
      |> Map.new(fn
        {{:ok, {name, {status, detail}}}, _} -> {name, %{status: status, detail: detail}}
        {{:exit, _}, name} -> {name, %{status: :error, detail: "check timed out"}}
      end)

    %{status: overall(components), components: components, checked_at: DateTime.utc_now()}
  end

  def overall(components) do
    counted = Enum.reject(components, fn {_, c} -> c.status == :not_configured end)

    cond do
      Enum.any?(counted, fn {name, c} -> name in @critical and c.status == :error end) -> "down"
      Enum.any?(counted, fn {_, c} -> c.status in [:warning, :error] end) -> "degraded"
      true -> "ok"
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, nil, {:continue, :check}}
  end

  @impl true
  def handle_continue(:check, state), do: {:noreply, check(state)}

  @impl true
  def handle_call({:put, result}, _from, state) do
    :ets.insert(@table, {:result, result})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:check, state), do: {:noreply, check(state)}

  defp check(state) do
    :ets.insert(@table, {:result, run()})
    Process.send_after(self(), :check, Keyword.get(config(), :interval, 10_000))
    state
  end

  defp config, do: Application.get_env(:qpbx, __MODULE__, [])
end
