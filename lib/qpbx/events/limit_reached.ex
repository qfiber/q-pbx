defmodule QPBX.Events.LimitReached do
  @moduledoc """
  Call admission refused a call because of a limit: `limit` names it (a plan limit such as
  `minutes_international_per_day`, or "destination_class", "fraud_block"), `detail` says more.
  Feeds the `limit.reached` webhook (phase 3). Version 1.
  """
  @enforce_keys [:tenant_id, :limit, :at]
  defstruct version: 1, tenant_id: nil, limit: nil, detail: nil, at: nil

  def topic, do: "limits"
end
