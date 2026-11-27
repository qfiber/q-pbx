defmodule QPBX.Web.SessionReaper do
  @moduledoc """
  Disconnects the live pages of ended sessions: on `QPBX.Events.SessionsRevoked` it broadcasts
  "disconnect" to each session's socket id, so a revoked browser loses its open pages at once.
  """
  use GenServer
  alias QPBX.Events.SessionsRevoked

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    QPBX.Events.subscribe(SessionsRevoked)
    {:ok, nil}
  end

  @impl true
  def handle_info({:event, %SessionsRevoked{session_ids: ids}}, state) do
    for id <- ids, do: QPBX.Web.Endpoint.broadcast(QPBX.Web.Auth.socket_id(id), "disconnect", %{})
    {:noreply, state}
  end
end
