defmodule QPBX.Web.Captcha.Pow do
  @moduledoc """
  Built-in proof of work in the ALTCHA format: the server picks a secret number, sends
  `sha256(salt <> number)` signed with HMAC, and the browser finds the number by trying them
  all (about a second). The answer is checked, must not have expired (5 minutes) and is
  accepted once. Bots then pay CPU time for every attempt; people barely notice.
  """
  @behaviour QPBX.Web.Captcha

  @max_number 60_000
  @ttl 300

  def challenge do
    expires = System.os_time(:second) + @ttl
    salt = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower) <> "?expires=#{expires}"
    number = :rand.uniform(@max_number + 1) - 1
    challenge = sha256(salt <> Integer.to_string(number))

    %{
      algorithm: "SHA-256",
      challenge: challenge,
      maxnumber: @max_number,
      salt: salt,
      signature: sign(challenge)
    }
  end

  @impl true
  def verify(%{"pow" => payload}, _ip) when is_binary(payload) and payload != "" do
    with {:ok, json} <- Base.decode64(payload),
         {:ok,
          %{
            "algorithm" => "SHA-256",
            "challenge" => c,
            "number" => n,
            "salt" => salt,
            "signature" => sig
          }} <-
           Jason.decode(json),
         true <- is_integer(n) and is_binary(c) and is_binary(salt) and is_binary(sig),
         true <- Plug.Crypto.secure_compare(sig, sign(c)),
         true <- not_expired?(salt),
         true <- Plug.Crypto.secure_compare(c, sha256(salt <> Integer.to_string(n))),
         :ok <- QPBX.Web.Captcha.PowStore.use_once(c, @ttl) do
      :ok
    else
      _ -> {:error, :invalid}
    end
  end

  def verify(_params, _ip), do: {:error, :missing}

  defp not_expired?(salt) do
    with [_, query] <- String.split(salt, "?", parts: 2),
         %{"expires" => e} <- URI.decode_query(query),
         {expires, ""} <- Integer.parse(e) do
      expires > System.os_time(:second)
    else
      _ -> false
    end
  end

  defp sha256(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)

  defp sign(challenge),
    do:
      :crypto.mac(:hmac, :sha256, Application.fetch_env!(:qpbx, :token_secret), challenge)
      |> Base.encode16(case: :lower)
end

defmodule QPBX.Web.Captcha.PowStore do
  @moduledoc """
  Remembers solved challenges until they expire, so each is accepted once.
  shortcut: per node (ETS); with several app nodes an answer could be replayed once per node
  within 5 minutes, move to a shared store when the second node arrives (phase 9).
  """
  use GenServer
  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "`:ok` the first time a challenge is presented, `:reused` after."
  def use_once(challenge, ttl) do
    if :ets.insert_new(@table, {challenge, System.os_time(:second) + ttl}), do: :ok, else: :reused
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :clean, 60_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:clean, state) do
    now = System.os_time(:second)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :clean, 60_000)
    {:noreply, state}
  end
end
