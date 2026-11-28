defmodule QPBX.Web.Api.EventSocket do
  @moduledoc """
  `/v1/socket` (Phoenix channels over WebSocket): the live event stream for a tenant's API key
  with the `read` scope. The key travels in the handshake's `Sec-WebSocket-Protocol` header
  (`phoenix, base64url.bearer.phx.<base64 of the key, no padding>`; the Phoenix JS client's
  `authToken` option), never in the URL, so it stays out of logs. The connection counts
  against the key's rate limit. Its id is `api_key_socket:<key id>`: revoking the key closes
  every open stream of it at once, and each channel re-checks the key every minute (expiry).
  """
  use Phoenix.Socket
  alias QPBX.Core
  alias QPBX.Core.ApiKey
  alias QPBX.Web.Api.RateLimit

  channel "events", QPBX.Web.Api.EventChannel

  @impl true
  def connect(_params, socket, connect_info) do
    with token when is_binary(token) <- connect_info[:auth_token],
         {:ok, %ApiKey{tenant_id: tid} = key} when is_binary(tid) <-
           Core.authenticate_api_key(token),
         true <- ApiKey.allows?(key, "read"),
         {:ok, _} <- RateLimit.hit(key.id, Core.api_rate_limit(key)) do
      {:ok, assign(socket, api_key: key, token: token, tenant_id: tid)}
    else
      _ -> :error
    end
  end

  @impl true
  def id(socket), do: socket_id(socket.assigns.api_key.id)

  @doc "The topic a key's sockets listen on; a \"disconnect\" broadcast there closes them."
  def socket_id(key_id), do: "api_key_socket:" <> key_id
end
