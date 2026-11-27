defmodule QPBX.Firewall.Sync do
  @moduledoc """
  Keeps this node's nftables sets equal to the database. Runs on every node: on each
  `FirewallChanged` event (broadcast to the whole cluster) and every 60 seconds, so a node that
  was offline or restarted catches up on its own. Every run replaces each managed set in full,
  which also repairs drift made outside Q-PBX.

  Lockout guard: if the database holds no active management entry, the SSH allow sets are left
  as they are (the Ansible base ruleset seeds them) rather than emptied.
  """
  use GenServer
  require Logger
  alias QPBX.Events
  alias QPBX.Events.FirewallChanged
  alias QPBX.Firewall.{Helper, Sets, Store}

  @ssh_allow ~w(allow_ssh_v4 allow_ssh_v6)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Reconciles now and returns the result."
  def run_now, do: GenServer.call(__MODULE__, :reconcile, 60_000)

  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    Events.subscribe(FirewallChanged)
    if config()[:reconcile_on_start] == false, do: schedule(), else: send(self(), :tick)
    {:ok, %{last: nil}}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    result = reconcile()
    {:reply, result, %{state | last: result}}
  end

  def handle_call(:status, _from, state), do: {:reply, state.last, state}

  @impl true
  def handle_info(:tick, state) do
    schedule()
    {:noreply, %{state | last: reconcile()}}
  end

  def handle_info({:event, %FirewallChanged{}}, state),
    do: {:noreply, %{state | last: reconcile()}}

  @doc false
  def reconcile do
    started = System.monotonic_time()

    result =
      try do
        desired = Store.active_entries() |> Sets.desired()
        skip = if Enum.all?(@ssh_allow, &(desired[&1] == [])), do: @ssh_allow, else: []

        if skip != [],
          do:
            Logger.warning(
              "firewall: no management entries in the database; SSH allow sets left unchanged"
            )

        errors =
          for {set, addresses} <- Enum.sort(desired), set not in skip, reduce: [] do
            acc ->
              case Helper.replace(set, addresses) do
                :ok -> acc
                {:error, reason} -> [{set, reason} | acc]
              end
          end

        if errors != [], do: Logger.error("firewall: helper refused #{inspect(errors)}")
        %{at: DateTime.utc_now(), errors: Enum.reverse(errors), skipped: skip}
      rescue
        # The database may be down; keep the current nftables state and try again next tick.
        e ->
          Logger.error("firewall: reconcile failed: #{Exception.message(e)}")
          %{at: DateTime.utc_now(), errors: [{:reconcile, Exception.message(e)}], skipped: []}
      end

    :telemetry.execute(
      [:qpbx, :firewall, :sync],
      %{duration: System.monotonic_time() - started, errors: length(result.errors)},
      %{}
    )

    result
  end

  defp schedule, do: Process.send_after(self(), :tick, config()[:reconcile_interval] || 60_000)
  defp config, do: Application.get_env(:qpbx, QPBX.Firewall, [])
end
