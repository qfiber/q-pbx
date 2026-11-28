defmodule QPBX.Events.UsageSummary do
  @moduledoc """
  A tenant's usage for a finished month: `month` ("2026-11"), `totals` (per direction: calls,
  answered, minutes). Version 1.
  """
  @enforce_keys [:tenant_id, :month, :at]
  defstruct version: 1, tenant_id: nil, month: nil, totals: %{}, at: nil

  def topic, do: "usage_summary"
end
