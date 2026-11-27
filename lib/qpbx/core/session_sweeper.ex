defmodule QPBX.Core.SessionSweeper do
  @moduledoc "Ends idle and expired sessions every 30 seconds (their live pages disconnect)."
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      QPBX.Core.Sessions.sweep()
    rescue
      # Database down: sessions are still checked per request; try again next round.
      e -> Logger.error("session sweep failed: #{Exception.message(e)}")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule,
    do: Process.send_after(self(), :sweep, Application.get_env(:qpbx, :session_sweep_ms, 30_000))
end
