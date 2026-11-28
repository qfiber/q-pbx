defmodule QPBX.Integrations.Webhooks.Dispatcher do
  @moduledoc """
  Subscribes to the bus events webhooks carry and hands each to
  `QPBX.Integrations.Webhooks.dispatch/1`. One process: events are queued in its mailbox, and
  a failure on one event is logged without losing the next.
  """
  use GenServer
  require Logger
  alias QPBX.Integrations.Webhooks

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    for source <- Webhooks.Event.sources(), do: QPBX.Events.subscribe(source)
    {:ok, nil}
  end

  @impl true
  def handle_info({:event, event}, state) do
    Webhooks.dispatch(event)
    {:noreply, state}
  rescue
    e ->
      Logger.error("webhooks: event not dispatched: #{Exception.message(e)}")
      {:noreply, state}
  end
end
