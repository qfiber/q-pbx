defmodule QPBX.Events.EdgeAlert do
  @moduledoc """
  The SIP edge would have banned a tenant office IP (flood, scanner or repeated failed logins)
  but office IPs are never banned as a whole: someone should look. Version 1.
  """
  @enforce_keys [:ip, :reason, :at]
  defstruct version: 1, ip: nil, reason: nil, at: nil

  def topic, do: "edge_alerts"
end
