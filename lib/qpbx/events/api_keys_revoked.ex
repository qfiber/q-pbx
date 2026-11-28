defmodule QPBX.Events.ApiKeysRevoked do
  @moduledoc """
  API keys were revoked: their open event-stream sockets are closed at once
  (`QPBX.Web.SessionReaper`). Version 1.
  """
  @enforce_keys [:key_ids, :at]
  defstruct version: 1, key_ids: [], at: nil

  def topic, do: "api_keys"
end
