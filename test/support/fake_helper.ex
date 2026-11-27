defmodule QPBX.FakeHelper do
  @moduledoc "Test stand-in for qpbx-fwd: keeps the last replace per set in an ETS table."
  use Boundary, top_level?: true, check: [in: false, out: false]
  @behaviour QPBX.Firewall.Helper

  @table __MODULE__

  def reset do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :public, :set])
    :ets.delete_all_objects(@table)
    :ok
  end

  def fail_with(reason), do: :ets.insert(@table, {:fail, reason})
  def sets, do: :ets.tab2list(@table) |> Enum.reject(&match?({:fail, _}, &1)) |> Map.new()

  @impl true
  def replace(set, addresses) do
    case :ets.lookup(@table, :fail) do
      [{:fail, reason}] ->
        {:error, reason}

      [] ->
        :ets.insert(@table, {set, addresses})
        :ok
    end
  end
end
