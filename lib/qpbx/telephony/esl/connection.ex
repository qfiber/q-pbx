defmodule QPBX.Telephony.ESL.Connection do
  @moduledoc """
  The one event socket connection to the local FreeSWITCH (inbound mode, 127.0.0.1:8021).
  Authenticates, subscribes to channel events and hands each event to `QPBX.Telephony.Calls`.
  Commands (`api/1`, `sendmsg/3`) are answered in the order sent, so callers wait in a queue.
  Reconnects with backoff; while it is down, parked calls end on their park timeout.
  """
  use GenServer
  require Logger
  alias QPBX.Telephony.Calls
  alias QPBX.Telephony.ESL.Frame

  @events ~w(CHANNEL_PARK CHANNEL_ANSWER CHANNEL_BRIDGE CHANNEL_UNBRIDGE CHANNEL_EXECUTE_COMPLETE
             CHANNEL_HANGUP_COMPLETE BACKGROUND_JOB)
  @timeout 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs an API command; `{:ok, body}` or `{:error, reason}`."
  def api(command), do: call({:send, Frame.command("api " <> command)})

  @doc "Runs a dialplan application on a channel (async); the result arrives as CHANNEL_EXECUTE_COMPLETE with Application-UUID = `event_uuid`."
  def execute(uuid, app, arg, event_uuid) do
    headers = [
      {"call-command", "execute"},
      {"execute-app-name", app},
      {"Event-UUID", event_uuid}
    ]

    # The argument goes as a body: no length or character limits of a header line.
    arg = arg || ""

    call(
      {:send,
       [
         "sendmsg ",
         uuid,
         "\n",
         Enum.map(headers, fn {k, v} -> [k, ": ", v, "\n"] end),
         "content-type: text/plain\ncontent-length: ",
         Integer.to_string(byte_size(arg)),
         "\n\n",
         arg
       ]}
    )
  end

  @doc "Hangs up a channel with a cause."
  def hangup(uuid, cause),
    do:
      call(
        {:send,
         Frame.command("sendmsg " <> uuid, [{"call-command", "hangup"}, {"hangup-cause", cause}])}
      )

  def connected?, do: GenServer.call(__MODULE__, :connected?)

  defp call(msg) do
    GenServer.call(__MODULE__, msg, @timeout + 1_000)
  catch
    :exit, reason -> {:error, {:esl, reason}}
  end

  ## Server

  @impl true
  def init(opts) do
    send(self(), :connect)
    {:ok, %{sock: nil, buffer: "", waiting: :queue.new(), stage: :down, backoff: 500, opts: opts}}
  end

  @impl true
  def handle_call(:connected?, _from, s), do: {:reply, s.stage == :ready, s}

  def handle_call({:send, _}, _from, %{stage: stage} = s) when stage != :ready,
    do: {:reply, {:error, :not_connected}, s}

  def handle_call({:send, data}, from, s) do
    case :gen_tcp.send(s.sock, data) do
      :ok -> {:noreply, %{s | waiting: :queue.in(from, s.waiting)}}
      {:error, e} -> {:reply, {:error, e}, s}
    end
  end

  @impl true
  def handle_info(:connect, s) do
    cfg = Application.get_env(:qpbx, QPBX.Telephony, [])
    host = String.to_charlist(cfg[:esl_host] || "127.0.0.1")

    case :gen_tcp.connect(
           host,
           cfg[:esl_port] || 8021,
           [:binary, active: true, packet: :raw],
           @timeout
         ) do
      {:ok, sock} ->
        {:noreply, %{s | sock: sock, stage: :auth, buffer: ""}}

      {:error, reason} ->
        Logger.warning("freeswitch: event socket connect failed (#{inspect(reason)}), retrying")
        {:noreply, retry(s)}
    end
  end

  def handle_info({:tcp, _sock, data}, s) do
    {frames, rest} = Frame.parse(s.buffer <> data)
    {:noreply, Enum.reduce(frames, %{s | buffer: rest}, &frame/2)}
  end

  def handle_info({:tcp_closed, _}, s), do: {:noreply, down(s, :closed)}
  def handle_info({:tcp_error, _, reason}, s), do: {:noreply, down(s, reason)}

  defp frame(%{headers: %{"Content-Type" => "auth/request"}}, s) do
    password = Application.get_env(:qpbx, QPBX.Telephony, [])[:esl_password] || "ClueCon"
    :ok = :gen_tcp.send(s.sock, Frame.command("auth " <> password))
    %{s | stage: :authenticating}
  end

  defp frame(
         %{headers: %{"Content-Type" => "command/reply", "Reply-Text" => reply}},
         %{stage: :authenticating} = s
       ) do
    if String.starts_with?(reply, "+OK") do
      :ok = :gen_tcp.send(s.sock, Frame.command("event json " <> Enum.join(@events, " ")))
      %{s | stage: :subscribing}
    else
      Logger.error("freeswitch: event socket refused the password")
      down(s, :auth_failed)
    end
  end

  defp frame(%{headers: %{"Content-Type" => "command/reply"}}, %{stage: :subscribing} = s) do
    Logger.info("freeswitch: event socket connected")
    %{s | stage: :ready, backoff: 500}
  end

  defp frame(%{headers: %{"Content-Type" => "text/event-json"}, body: event}, s)
       when is_map(event) do
    Calls.dispatch(event)
    s
  end

  defp frame(%{headers: %{"Content-Type" => type} = h, body: body}, s)
       when type in ["command/reply", "api/response"] do
    reply = if type == "api/response", do: body || "", else: h["Reply-Text"] || ""

    case :queue.out(s.waiting) do
      {{:value, from}, rest} ->
        GenServer.reply(
          from,
          if(String.starts_with?(reply, "-ERR"), do: {:error, reply}, else: {:ok, reply})
        )

        %{s | waiting: rest}

      {:empty, _} ->
        s
    end
  end

  defp frame(%{headers: %{"Content-Type" => "text/disconnect-notice"}}, s),
    do: down(s, :disconnect_notice)

  defp frame(_other, s), do: s

  defp down(s, reason) do
    if s.sock, do: :gen_tcp.close(s.sock)
    Logger.warning("freeswitch: event socket down (#{inspect(reason)})")
    for from <- :queue.to_list(s.waiting), do: GenServer.reply(from, {:error, :disconnected})
    retry(%{s | sock: nil, stage: :down, waiting: :queue.new(), buffer: ""})
  end

  defp retry(s) do
    Process.send_after(self(), :connect, s.backoff)
    %{s | backoff: min(s.backoff * 2, 10_000)}
  end
end
