defmodule QPBX.Edge.Reloader do
  @moduledoc """
  Reloads Kamailio's in-memory configuration when it changes, so it applies on the next
  request with no Kamailio restart: credentials and tenant domains (Core events), trunks and
  registrations (`ConfigChanged` "trunks"), allow lists (`FirewallChanged`). Every minute it
  also reloads the allow lists (entries expire) and reconciles registrations (a restarted
  Kamailio has none). A failed action is retried; a Kamailio restart reloads the views itself.
  """
  use GenServer
  require Logger
  alias QPBX.Edge
  alias QPBX.Edge.Registrations
  alias QPBX.Events
  alias QPBX.Events.{ConfigChanged, FirewallChanged, SipCredentialsChanged, TenantsChanged}

  @retry_ms 5_000
  @attempts 5
  @every_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    for e <- [SipCredentialsChanged, TenantsChanged, ConfigChanged, FirewallChanged],
        do: Events.subscribe(e)

    Process.send_after(self(), :periodic, 1_000)
    {:ok, nil}
  end

  @impl true
  def handle_info({:event, %SipCredentialsChanged{}}, s), do: {:noreply, run(:credentials, 1, s)}
  def handle_info({:event, %TenantsChanged{}}, s), do: {:noreply, run(:domains, 1, s)}

  def handle_info({:event, %ConfigChanged{kind: "trunks"}}, s),
    do: {:noreply, run(:registrations, 1, run(:trunks, 1, s))}

  def handle_info({:event, %ConfigChanged{}}, s), do: {:noreply, s}
  def handle_info({:event, %FirewallChanged{}}, s), do: {:noreply, run(:allowlist, 1, s)}
  def handle_info({:retry, action, attempt}, s), do: {:noreply, run(action, attempt, s)}

  def handle_info(:periodic, s) do
    Process.send_after(self(), :periodic, @every_ms)
    {:noreply, run(:registrations, @attempts, run(:allowlist, @attempts, s))}
  end

  defp run(action, attempt, s) do
    case perform(action) do
      :ok ->
        s

      {:error, reason} when attempt < @attempts ->
        Logger.warning("kamailio: #{action} failed (#{inspect(reason)}), retrying")
        Process.send_after(self(), {:retry, action, attempt + 1}, @retry_ms)
        s

      {:error, reason} ->
        Logger.error("kamailio: #{action} failed: #{inspect(reason)}")
        s
    end
  end

  defp perform(:credentials), do: Edge.reload("credentials")
  defp perform(:domains), do: Edge.reload("domains")
  defp perform(:trunks), do: Edge.reload_trunks()
  defp perform(:allowlist), do: Edge.reload_allowlist()
  defp perform(:registrations), do: Registrations.sync()
end
