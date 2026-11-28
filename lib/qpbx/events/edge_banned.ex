defmodule QPBX.Events.EdgeBanned do
  @moduledoc """
  Kamailio banned an address (`port` nil) or one phone (`ip` and `port`) for `reason` (flood,
  scanner, rate, auth failures). `domain`: the SIP domain the failed logins were for, when
  known. Version 1.
  """
  @enforce_keys [:ip, :reason, :at]
  defstruct version: 1, ip: nil, port: nil, reason: nil, domain: nil, at: nil

  def topic, do: "edge_bans"
end
