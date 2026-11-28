defmodule QPBX.Web.SessionReaper do
  @moduledoc """
  Disconnects the live pages of ended sessions: on `QPBX.Events.SessionsRevoked` it broadcasts
  "disconnect" to each session's socket id, so a revoked browser loses its open pages at once.
  The same for revoked API keys (`QPBX.Events.ApiKeysRevoked`): their event streams close.
  """
  use GenServer
  alias QPBX.Events.{ApiKeysRevoked, SessionsRevoked}
  alias QPBX.Web.Api.EventSocket
  alias QPBX.Web.{Auth, Endpoint}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    QPBX.Events.subscribe(SessionsRevoked)
    QPBX.Events.subscribe(ApiKeysRevoked)
    {:ok, nil}
  end

  @impl true
  def handle_info({:event, %SessionsRevoked{session_ids: ids}}, state) do
    for id <- ids, do: Endpoint.broadcast(Auth.socket_id(id), "disconnect", %{})
    {:noreply, state}
  end

  def handle_info({:event, %ApiKeysRevoked{key_ids: ids}}, state) do
    for id <- ids, do: Endpoint.broadcast(EventSocket.socket_id(id), "disconnect", %{})

    {:noreply, state}
  end
end
