defmodule QPBX.Edge.TrunkMonitor do
  @moduledoc """
  Watches the trunks every 15 seconds: an IP trunk is down when none of its addresses is
  active in Kamailio's dispatcher (its OPTIONS pings); a registration trunk when its
  registration is not online. A change seen twice in a row publishes `TrunkStatusChanged`.
  `status/0` gives the latest view (the `trunk_registrations` health check).
  """
  use GenServer
  require Logger
  alias QPBX.{Core, Edge}
  alias QPBX.Events
  alias QPBX.Events.TrunkStatusChanged

  @every_ms 15_000
  # uac registration flag: registered at the carrier.
  @online 4

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "`%{trunk_id => %{name, tenant_id, up, reason}}` from the last round (empty before the first)."
  def status do
    GenServer.call(__MODULE__, :status, 2_000)
  catch
    :exit, _ -> %{}
  end

  @impl true
  def init(_) do
    Process.send_after(self(), :poll, 5_000)
    # seen: the last state read; told: the state last published; streak: rounds of `seen`.
    {:ok, %{seen: %{}, told: %{}, streak: %{}, view: %{}}}
  end

  @impl true
  def handle_call(:status, _from, s), do: {:reply, s.view, s}

  @impl true
  def handle_info(:poll, s) do
    Process.send_after(self(), :poll, @every_ms)
    {:noreply, poll(s)}
  rescue
    e ->
      Logger.warning("trunks: status round failed: #{Exception.message(e)}")
      {:noreply, s}
  end

  @doc false
  # One round: the current view of every enabled trunk, and the changes to announce.
  def poll(s), do: round_with(s, read_states())

  @doc false
  def round_with(s, now_view) do
    s |> forget_removed(now_view) |> judge(now_view)
  end

  # A trunk told down that is gone (deleted or disabled): its alert ends with it.
  # shortcut: a trunk deleted while the app was stopped keeps its open alert; resolve it by hand.
  defp forget_removed(s, now_view) do
    gone = for {id, false} <- s.told, not Map.has_key?(now_view, id), do: id

    for id <- gone do
      t = s.view[id] || %{name: nil, tenant_id: nil}

      Events.publish(%TrunkStatusChanged{
        trunk_id: id,
        tenant_id: t.tenant_id,
        name: t.name,
        up: true,
        reason: "removed",
        at: DateTime.utc_now()
      })
    end

    %{
      s
      | told: Map.drop(s.told, gone),
        seen: Map.drop(s.seen, gone),
        streak: Map.drop(s.streak, gone)
    }
  end

  defp judge(s, now_view) do
    Enum.reduce(now_view, %{s | view: now_view}, fn {id, t}, acc ->
      streak = if acc.seen[id] == t.up, do: (acc.streak[id] || 1) + 1, else: 1
      acc = %{acc | seen: Map.put(acc.seen, id, t.up), streak: Map.put(acc.streak, id, streak)}

      # Twice in a row, and different from what was told (a first "up" is not news).
      if streak >= 2 and acc.told[id] != t.up and not (is_nil(acc.told[id]) and t.up) do
        Events.publish(%TrunkStatusChanged{
          trunk_id: id,
          tenant_id: t.tenant_id,
          name: t.name,
          up: t.up,
          reason: t.reason,
          at: DateTime.utc_now()
        })

        %{acc | told: Map.put(acc.told, id, t.up)}
      else
        %{acc | told: Map.put_new(acc.told, id, if(t.up, do: true, else: nil))}
      end
    end)
  end

  defp read_states do
    trunks = Core.telephony_platform().trunks |> Map.values() |> Enum.filter(& &1.enabled)
    sets = dispatcher_sets()
    regs = registrations()

    Map.new(trunks, fn t ->
      {up, reason} =
        case t.auth_mode do
          "registration" -> reg_state(regs[t.id])
          _ -> ds_state(sets[t.edge_id])
        end

      {t.id, %{name: t.name, tenant_id: t.tenant_id, up: up, reason: reason}}
    end)
  end

  defp reg_state(nil), do: {false, "not registered at the carrier"}

  defp reg_state(r),
    do:
      if(Bitwise.band(to_int(r["flags"]), @online) == @online,
        do: {true, nil},
        else: {false, "registration failed"}
      )

  # No set loaded yet (Kamailio just started or the trunk is new): treat as up until known.
  defp ds_state(nil), do: {true, nil}

  defp ds_state(flags) do
    if Enum.any?(flags, &String.starts_with?(&1, "A")),
      do: {true, nil},
      else: {false, "no address answers OPTIONS"}
  end

  # %{set id => [FLAGS of each address]}; an empty dispatcher answers an error.
  defp dispatcher_sets do
    case Edge.rpc("dispatcher.list") do
      {:ok, %{"RECORDS" => records}} ->
        for %{"SET" => %{"ID" => id, "TARGETS" => targets}} <- List.wrap(records), into: %{} do
          {to_int(id), for(%{"DEST" => d} <- List.wrap(targets), do: d["FLAGS"] || "")}
        end

      _ ->
        %{}
    end
  end

  defp registrations do
    case Edge.rpc("uac.reg_dump") do
      {:ok, list} when is_list(list) -> Map.new(list, &{&1["l_uuid"], &1})
      _ -> %{}
    end
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: String.to_integer(v)
  defp to_int(_), do: 0
end
