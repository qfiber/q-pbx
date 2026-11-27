defmodule QPBX.Edge do
  @moduledoc """
  Public API of the edge area: Kamailio integration. Kamailio keeps tenant domains and SIP
  credential hashes in memory (htable), loaded from read-only database views; this area tells
  it to reload a table when Core announces a change. See `lib/qpbx/edge/README.md`.
  """
  use Boundary, deps: [QPBX.Events], exports: [Reloader]

  @doc ~s(Asks Kamailio to reload one of its in-memory tables: "credentials" or "domains".)
  def reload(table) when table in ["credentials", "domains"] do
    case config()[:jsonrpc_url] do
      nil ->
        :ok

      url ->
        body = %{jsonrpc: "2.0", method: "htable.reload", params: [table], id: 1}

        case Req.post(
               [url: url, json: body, receive_timeout: 5_000, retry: false] ++
                 (config()[:req_options] || [])
             ) do
          {:ok, %{status: 200, body: %{"result" => _}}} -> :ok
          {:ok, %{body: body}} -> {:error, body}
          {:error, e} -> {:error, e}
        end
    end
  end

  def config, do: Application.get_env(:qpbx, __MODULE__, [])
end
