defmodule QPBX.Edge.Bans do
  @moduledoc """
  Carries Kamailio's whole-address bans to nftables and raises office-IP alerts. Kamailio
  detects (floods, scanners, failed logins) and bans in memory at once; every 5 s this reads
  its `ipban` and `edgealert` tables. A new whole-address ban becomes a firewall block entry
  with an expiry (`QPBX.Firewall.ban/4`: dropped in the kernel even while the app is down); a
  new alert is logged, audited and announced (`EdgeAlert`). Bans of one address and port stay
  in Kamailio only (many phones share an office address).
  """
  use GenServer
  require Logger
  alias QPBX.Edge
  alias QPBX.Events
  alias QPBX.Events.EdgeAlert

  @every_ms 5_000
  @actor {:system, "edge"}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :poll, @every_ms)
    {:ok, %{pushed: MapSet.new(), alerted: MapSet.new()}}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @every_ms)
    {:noreply, poll(state)}
  end

  @doc false
  # One round; the state remembers what was handled, so a ban or alert is acted on once while
  # Kamailio holds it (and again after it expired and comes back).
  def poll(state) do
    with {:ok, bans} <- table("ipban"), {:ok, alerts} <- table("edgealert") do
      bans = lift_allowed(bans)

      whole =
        for {key, reason} <- bans, not String.contains?(key, "|"), into: %{}, do: {key, reason}

      for {ip, reason} <- whole, not MapSet.member?(state.pushed, ip), do: push(ip, reason)
      for {ip, reason} <- alerts, not MapSet.member?(state.alerted, ip), do: alert(ip, reason)
      %{pushed: MapSet.new(Map.keys(whole)), alerted: MapSet.new(Enum.map(alerts, &elem(&1, 0)))}
    else
      {:error, reason} ->
        Logger.warning("edge: cannot read Kamailio's bans: #{inspect(reason)}")
        state
    end
  end

  # A ban placed before Kamailio learned that the address is allowed (the allow list reloads a
  # few seconds after a change) is lifted: every ban on the platform SIP allowlist, and the
  # whole-address ban of an office IP (its per-phone bans stay).
  defp lift_allowed(bans) do
    Enum.reject(bans, fn {key, _reason} ->
      [ip | port] = String.split(key, "|")

      lift? =
        case :inet.parse_strict_address(String.to_charlist(ip)) do
          {:ok, tuple} ->
            QPBX.Firewall.allowlisted?(tuple, "sip") or
              (port == [] and QPBX.Firewall.office_ip?(tuple))

          _ ->
            false
        end

      if lift? do
        Logger.warning("edge: lifting Kamailio ban of #{key}: the address is allowed")
        Edge.rpc("htable.delete", ["ipban", key])
      end

      lift?
    end)
  end

  defp push(ip, reason) do
    case QPBX.Firewall.ban(ip, reason, ban_seconds(), @actor) do
      {:ok, %{expires_at: until}} ->
        Logger.warning("edge: #{ip} blocked in the firewall until #{until} (#{reason})")

      {:ok, skipped} ->
        Logger.warning("edge: #{ip} not blocked in the firewall (#{skipped})")

      {:error, e} ->
        Logger.error("edge: blocking #{ip} failed: #{inspect(e)}")
    end
  end

  defp alert(ip, reason) do
    Logger.warning("edge: ALERT office IP #{ip} would have been banned (#{reason})")
    QPBX.Core.audit(@actor, "edge.office_ip_alert", nil, %{ip: ip, reason: reason})
    Events.publish(%EdgeAlert{ip: ip, reason: reason, at: DateTime.utc_now()})
  end

  # htable.dump answers a list of hash slots, each with its items.
  defp table(name) do
    with {:ok, slots} <- Edge.rpc("htable.dump", [name]) do
      {:ok,
       for(
         %{"slot" => items} <- List.wrap(slots),
         %{"name" => k, "value" => v} <- items,
         do: {k, to_string(v)}
       )}
    end
  end

  defp ban_seconds, do: Edge.config()[:ban_seconds] || 3600
end
