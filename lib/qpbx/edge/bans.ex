defmodule QPBX.Edge.Bans do
  @moduledoc """
  Keeps Kamailio's bans on disk, carries whole-address bans to nftables, and raises office-IP
  alerts. Kamailio detects (floods, scanners, failed logins) and bans in memory at once; every
  5 s this reads its `ipban` and `edgealert` tables. Each new ban is stored (`edge_bans`, which
  a restarted Kamailio loads back through the `kamailio.ipban` view); a new whole-address ban
  also becomes a firewall block with an expiry (`QPBX.Firewall.ban/4`: dropped in the kernel
  even while the app is down). Bans of one address and port stay out of nftables (many phones
  share an office address). A new alert is logged, audited and announced (`EdgeAlert`).
  """
  use GenServer
  require Logger
  import Ecto.Query
  alias QPBX.Edge
  alias QPBX.Edge.Ban
  alias QPBX.Events
  alias QPBX.Events.{EdgeAlert, EdgeBanned}
  alias QPBX.Repo

  @every_ms 5_000
  @actor {:system, "edge"}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :poll, @every_ms)
    {:ok, %{alerted: MapSet.new()}}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @every_ms)
    {:noreply, poll(state)}
  end

  @doc false
  # One round. A ban is handled once: its row in edge_bans says so (also across app restarts);
  # alerts once while Kamailio holds them.
  def poll(state) do
    with {:ok, bans} <- table("ipban"), {:ok, alerts} <- table("edgealert") do
      now = DateTime.utc_now()
      known = MapSet.new(Repo.all(from b in Ban, where: b.expires_at > ^now, select: b.key))
      seconds = Edge.get_settings().ban_seconds

      for {key, reason} <- lift_allowed(bans),
          not MapSet.member?(known, key),
          do: record(key, reason, seconds)

      for {ip, reason} <- alerts, not MapSet.member?(state.alerted, ip), do: alert(ip, reason)
      Repo.delete_all(from b in Ban, where: b.expires_at < ^DateTime.add(now, -1, :day))
      %{alerted: MapSet.new(Enum.map(alerts, &elem(&1, 0)))}
    else
      {:error, reason} ->
        Logger.warning("edge: cannot read Kamailio's bans: #{inspect(reason)}")
        state
    end
  end

  defp record(key, reason, seconds) do
    {ip, port} =
      case String.split(key, "|") do
        [ip, port] -> {ip, String.to_integer(port)}
        [ip] -> {ip, nil}
      end

    until = DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)

    Repo.insert!(%Ban{key: key, ip: ip, port: port, reason: reason, expires_at: until},
      on_conflict: {:replace, [:reason, :expires_at, :updated_at]},
      conflict_target: :key
    )

    if is_nil(port),
      do: push(ip, reason, seconds),
      else: Logger.warning("edge: banned #{ip}:#{port} (#{reason})")

    {kind, domain} =
      case reason do
        "auth failures " <> domain -> {"auth failures", domain}
        other -> {other, nil}
      end

    Events.publish(%EdgeBanned{
      ip: ip,
      port: port,
      reason: kind,
      domain: domain,
      at: DateTime.utc_now()
    })
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

  defp push(ip, reason, seconds) do
    case QPBX.Firewall.ban(ip, reason, seconds, @actor) do
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
end
