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

  def sets,
    do:
      for(
        {set, addresses} <- :ets.tab2list(@table),
        is_binary(set),
        into: %{},
        do: {set, addresses}
      )

  def timeouts(set),
    do: :ets.lookup(@table, {:timeouts, set}) |> Enum.map(&elem(&1, 1)) |> List.first(%{})

  @impl true
  def replace(set, addresses, timeouts) do
    case :ets.lookup(@table, :fail) do
      [{:fail, reason}] ->
        {:error, reason}

      [] ->
        :ets.insert(@table, {set, addresses})
        :ets.insert(@table, {{:timeouts, set}, timeouts})
        :ok
    end
  end
end
