defmodule QPBX.Edge.Reloader do
  @moduledoc """
  Reloads Kamailio's in-memory tables when Core announces a change, so new or changed
  credentials and tenant domains apply on the next request, with no Kamailio reload. A failed
  reload is retried; a Kamailio restart loads everything from the database anyway.
  """
  use GenServer
  require Logger
  alias QPBX.Events
  alias QPBX.Events.{SipCredentialsChanged, TenantsChanged}

  @retry_ms 5_000
  @attempts 5

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Events.subscribe(SipCredentialsChanged)
    Events.subscribe(TenantsChanged)
    {:ok, nil}
  end

  @impl true
  def handle_info({:event, %SipCredentialsChanged{}}, s),
    do: {:noreply, reload("credentials", 1, s)}

  def handle_info({:event, %TenantsChanged{}}, s), do: {:noreply, reload("domains", 1, s)}
  def handle_info({:retry, table, attempt}, s), do: {:noreply, reload(table, attempt, s)}

  defp reload(table, attempt, s) do
    case QPBX.Edge.reload(table) do
      :ok ->
        s

      {:error, reason} when attempt < @attempts ->
        Logger.warning("kamailio: reload #{table} failed (#{inspect(reason)}), retrying")
        Process.send_after(self(), {:retry, table, attempt + 1}, @retry_ms)
        s

      {:error, reason} ->
        Logger.error("kamailio: reload #{table} failed #{@attempts} times: #{inspect(reason)}")
        s
    end
  end
end
