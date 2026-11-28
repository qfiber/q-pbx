defmodule QPBX.Web.Api.RateLimit do
  @moduledoc """
  Requests per key per minute (fixed one-minute windows), counted in ETS on this node.
  shortcut: counts are per node; with active/standby only one node serves the API, so this
  holds until the API runs on several nodes at once.
  """
  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Counts one request for `key_id` against `limit` (nil: unlimited): `{:ok, remaining}` or
  `{:error, retry_after_seconds}`.
  """
  def hit(_key_id, nil), do: {:ok, nil}

  def hit(key_id, limit) do
    now = System.system_time(:second)
    count = :ets.update_counter(@table, {key_id, div(now, 60)}, 1, {{key_id, div(now, 60)}, 0})
    if count <= limit, do: {:ok, limit - count}, else: {:error, 60 - rem(now, 60)}
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    current = div(System.system_time(:second), 60)
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, 60_000)
end
