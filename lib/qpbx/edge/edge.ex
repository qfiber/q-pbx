defmodule QPBX.Edge do
  @moduledoc """
  Public API of the edge area: Kamailio integration. Kamailio keeps tenant domains,
  credential hashes, trunks (dispatcher) and allow lists in memory, loaded from read-only
  views in the `kamailio` schema; this area tells it to reload when something changes, and
  pushes registration trunks (with their passwords) over JSON-RPC. See `lib/qpbx/edge/README.md`.
  """
  use Boundary,
    deps: [QPBX.Repo, QPBX.Core, QPBX.Events, QPBX.Firewall, QPBX.Telephony],
    exports: [Reloader, Registrations, Bans, Settings, Ban, Presence]

  import Ecto.Query
  alias QPBX.Edge.{Ban, Settings}
  alias QPBX.Repo

  @htables ["credentials", "domains", "trunks", "settings"]

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

  ## Registrations reported by Kamailio

  @doc "A device's registration change from Kamailio (see `QPBX.Edge.RegistrationEvents`)."
  defdelegate registration_report(params), to: QPBX.Edge.RegistrationEvents, as: :report

  @doc "The shared secret Kamailio sends with its reports (nil: reports are refused)."
  def event_secret, do: config()[:event_secret]

  ## Protection settings (platform admins)

  def get_settings, do: Repo.get!(Settings, true)
  def change_settings(%Settings{} = s, attrs \\ %{}), do: Settings.changeset(s, attrs)

  @doc "Saves the settings (audited); Kamailio applies them within seconds, no restart."
  def update_settings(attrs, actor) do
    cs = Settings.changeset(get_settings(), attrs)

    result =
      Repo.transaction(fn ->
        with {:ok, s} <- Repo.update(cs),
             {:ok, _} <- QPBX.Core.audit(actor, "edge_settings.update", nil, cs.changes) do
          s
        else
          {:error, e} -> Repo.rollback(e)
        end
      end)

    with {:ok, _} <- result do
      QPBX.Events.publish(%QPBX.Events.ConfigChanged{
        kind: "edge_settings",
        at: DateTime.utc_now()
      })

      result
    end
  end

  ## Bans

  @doc "Active bans, newest first."
  def list_bans do
    now = DateTime.utc_now()
    Repo.all(from b in Ban, where: b.expires_at > ^now, order_by: [desc: b.inserted_at])
  end

  @doc """
  Lifts a ban now: in Kamailio, in the database, and for a whole address its automatic
  firewall block. Audited.
  """
  def lift_ban(key, actor) when is_binary(key) do
    ban = Repo.get(Ban, key)
    _ = rpc("htable.delete", ["ipban", key])
    if ban, do: Repo.delete!(ban)
    if ban && is_nil(ban.port), do: QPBX.Firewall.unban(ban.ip, actor)
    QPBX.Core.audit(actor, "edge_ban.lift", nil, %{key: key})
    :ok
  end

  def config, do: Application.get_env(:qpbx, __MODULE__, [])

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error
end
