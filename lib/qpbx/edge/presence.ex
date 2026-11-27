defmodule QPBX.Edge.Presence do
  @moduledoc """
  Feeds Kamailio's presence server, which answers the phones' subscriptions (busy lamps,
  presence, voicemail lights): every `CallState` becomes a `dialog` update, sent as JSON to
  Kamailio's localhost-only `/presence` endpoint (`pua_json`). Voicemail lights: every
  `VoicemailChanged` at once, and every extension's counts (`QPBX.Telephony.voicemail_counts/1`)
  at start, when extensions change and every 5 minutes. Kamailio keeps presence state in memory, so every
  minute this checks Kamailio's start time: after a restart (or a failed round) it republishes
  at once.
  """
  use GenServer
  require Logger
  alias QPBX.Edge
  alias QPBX.Events
  alias QPBX.Events.{CallState, ConfigChanged, VoicemailChanged}

  @mwi_every_ms 5 * 60_000
  @check_every_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Events.subscribe(CallState)
    Events.subscribe(ConfigChanged)
    Events.subscribe(VoicemailChanged)
    Process.send_after(self(), :mwi, 2_000)
    Process.send_after(self(), :check, @check_every_ms)
    {:ok, %{up_since: nil, failed: false}}
  end

  @impl true
  def handle_info({:event, %CallState{} = e}, s) do
    send_json(dialog(e))
    {:noreply, s}
  end

  def handle_info({:event, %ConfigChanged{kind: "extensions", tenant_id: tid}}, s) do
    publish_mwi(tid)
    {:noreply, s}
  end

  def handle_info({:event, %ConfigChanged{}}, s), do: {:noreply, s}

  def handle_info({:event, %VoicemailChanged{} = e}, s) do
    case List.keyfind(QPBX.Core.extension_addresses(e.tenant_id), e.extension_id, 0) do
      {_id, number, domain} -> send_json(mwi(number, domain, e.new, e.saved))
      nil -> :ok
    end

    {:noreply, s}
  end

  def handle_info(:mwi, s) do
    Process.send_after(self(), :mwi, @mwi_every_ms)
    {:noreply, %{s | failed: publish_mwi(nil) != :ok}}
  end

  # Kamailio restarted (its start time moved) or the last round failed: publish again now.
  def handle_info(:check, s) do
    Process.send_after(self(), :check, @check_every_ms)

    case Edge.rpc("core.uptime") do
      {:ok, %{"up_since" => since}} when since != s.up_since or s.failed ->
        if s.up_since,
          do: Logger.info("presence: Kamailio restarted or a round failed; republishing")

        {:noreply, %{s | up_since: since, failed: publish_mwi(nil) != :ok}}

      _ ->
        {:noreply, s}
    end
  end

  @doc "The `pua_json` dialog update for a call state (the presentity is the extension)."
  def dialog(%CallState{} = e) do
    peer = e.peer || e.extension

    %{
      "Event-Name" => "update",
      "Event-Package" => "dialog",
      "From" => "sip:#{e.extension}@#{e.domain}",
      "From-User" => e.extension,
      "From-Realm" => e.domain,
      "To" => "sip:#{peer}@#{e.domain}",
      "To-User" => peer,
      "To-Realm" => e.domain,
      "Call-ID" => e.call_id,
      "State" => e.state,
      "Direction" => e.direction,
      "Expires" => if(e.state == "terminated", do: "1", else: "3600")
    }
  end

  @doc "The `pua_json` message-summary update for an extension."
  def mwi(number, domain, new \\ 0, saved \\ 0) do
    account = "sip:#{number}@#{domain}"

    %{
      "Event-Name" => "update",
      "Event-Package" => "message-summary",
      "From" => account,
      "From-User" => number,
      "From-Realm" => domain,
      "Call-ID" => "mwi-#{number}@#{domain}",
      "Messages-Waiting" => if(new > 0, do: "yes", else: "no"),
      "Messages-New" => to_string(new),
      "Messages-Saved" => to_string(saved),
      "Messages-Urgent" => "0",
      "Messages-Urgent-Saved" => "0",
      "Message-Account" => account,
      "Expires" => "3600"
    }
  end

  defp publish_mwi(tenant_id) do
    if url() do
      counts = QPBX.Telephony.voicemail_counts(tenant_id)

      results =
        for {id, number, domain} <- QPBX.Core.extension_addresses(tenant_id) do
          {new, saved} = Map.get(counts, id, {0, 0})
          send_json(mwi(number, domain, new, saved))
        end

      if Enum.all?(results, &(&1 == :ok)), do: :ok, else: :error
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("presence: voicemail lights not published: #{Exception.message(e)}")
      :error
  end

  defp send_json(body) do
    with url when is_binary(url) <- url() do
      case Req.post(
             [url: url, json: body, receive_timeout: 2_000, retry: false] ++
               (Edge.config()[:req_options] || [])
           ) do
        {:ok, %{status: 200}} ->
          :ok

        other ->
          Logger.warning("presence: Kamailio refused an update: #{inspect(other)}")
          :error
      end
    end
  end

  defp url do
    case Edge.config()[:jsonrpc_url] do
      nil -> nil
      rpc -> String.replace(rpc, ~r{/RPC$}, "/presence")
    end
  end
end
