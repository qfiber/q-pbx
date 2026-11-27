defmodule QPBX.Events.SessionsRevoked do
  @moduledoc "Sessions ended (logout, revocation, timeout); their live pages must disconnect. Version 1."
  @enforce_keys [:session_ids, :at]
  defstruct version: 1, session_ids: [], at: nil

  def topic, do: "sessions"
end
