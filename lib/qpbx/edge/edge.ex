defmodule QPBX.Edge do
  @moduledoc """
  Public API of the edge area: Kamailio integration. Kamailio keeps tenant domains,
  credential hashes, trunks (dispatcher) and allow lists in memory, loaded from read-only
  views in the `kamailio` schema; this area tells it to reload when something changes, and
  pushes registration trunks (with their passwords) over JSON-RPC. See `lib/qpbx/edge/README.md`.
  """
  use Boundary, deps: [QPBX.Core, QPBX.Events], exports: [Reloader, Registrations]

  @htables ["credentials", "domains", "trunks"]

  @doc "Calls a Kamailio JSON-RPC method. `{:ok, result}` or `{:error, reason}`; `:ok`-like no-op when no Kamailio is configured."
  def rpc(method, params \\ []) do
    case config()[:jsonrpc_url] do
      nil ->
        {:ok, nil}

      url ->
        body = %{jsonrpc: "2.0", method: method, params: params, id: 1}

        opts =
          [url: url, json: body, receive_timeout: 5_000, retry: false] ++
            (config()[:req_options] || [])

        case Req.post(opts) do
          {:ok, %{status: 200, body: %{"result" => result}}} -> {:ok, result}
          {:ok, %{status: 200, body: %{"error" => error}}} -> {:error, error}
          {:ok, %{status: status}} -> {:error, {:http, status}}
          {:error, e} -> {:error, e}
        end
    end
  end

  @doc ~s(Reloads one of Kamailio's in-memory tables: "credentials", "domains" or "trunks".)
  def reload(table) when table in @htables, do: ok(rpc("htable.reload", [table]))

  @doc "Reloads trunks: their htable and the dispatcher sets (addresses, failover, pings)."
  def reload_trunks do
    with :ok <- reload("trunks"), do: ok(rpc("dispatcher.reload"))
  end

  @doc "Reloads the allow lists (platform SIP allows and tenant office IPs)."
  def reload_allowlist, do: ok(rpc("permissions.addressReload"))

  def config, do: Application.get_env(:qpbx, __MODULE__, [])

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error
end
