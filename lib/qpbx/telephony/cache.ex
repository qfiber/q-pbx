defmodule QPBX.Telephony.Cache do
  @moduledoc """
  The telephony configuration in memory (ETS) for call control: each tenant's snapshot, the
  platform's, and the DID index, loaded from Core on first use and dropped on any change
  (`ConfigChanged`, `SipCredentialsChanged`, `TenantsChanged`), so a change applies to the
  next call with no reload.
  """
  use GenServer
  alias QPBX.Core
  alias QPBX.Events
  alias QPBX.Events.{ConfigChanged, SipCredentialsChanged, TenantsChanged}

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def tenant(nil), do: nil

  def tenant(tenant_id),
    do: fetch({:tenant, tenant_id}, fn -> Core.telephony_tenant(tenant_id) end)

  def platform, do: fetch(:platform, &Core.telephony_platform/0)
  def dids, do: fetch(:dids, &Core.telephony_dids/0)

  @doc "Drops everything (the next call reloads)."
  def clear, do: :ets.delete_all_objects(@table)

  defp fetch(key, load) do
    case :ets.lookup(@table, key) do
      [{^key, value}] ->
        value

      [] ->
        value = load.()
        :ets.insert(@table, {key, value})
        value
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    for e <- [ConfigChanged, SipCredentialsChanged, TenantsChanged], do: Events.subscribe(e)
    {:ok, nil}
  end

  # Configuration changes are rare; dropping everything keeps this simple and always right.
  @impl true
  def handle_info({:event, _}, s) do
    clear()
    {:noreply, s}
  end
end
