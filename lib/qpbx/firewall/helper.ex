defmodule QPBX.Firewall.Helper do
  @moduledoc """
  Client for `qpbx-fwd`. The adapter is configured with `config :qpbx, QPBX.Firewall,
  helper: module`: `QPBX.Firewall.Helper.Socket` in production, a fake in tests, and
  `QPBX.Firewall.Helper.Noop` where no helper runs (development).
  """
  @doc "`timeouts`: seconds until the kernel drops an address (block sets only)."
  @callback replace(
              set :: String.t(),
              addresses :: [String.t()],
              timeouts :: %{String.t() => pos_integer()}
            ) ::
              :ok | {:error, term()}

  def replace(set, addresses, timeouts \\ %{}), do: adapter().replace(set, addresses, timeouts)

  defp adapter,
    do: Application.get_env(:qpbx, QPBX.Firewall, [])[:helper] || QPBX.Firewall.Helper.Noop
end

defmodule QPBX.Firewall.Helper.Noop do
  @moduledoc "No helper: changes are only logged (development without nftables)."
  @behaviour QPBX.Firewall.Helper
  require Logger

  @impl true
  def replace(set, addresses, _timeouts) do
    Logger.debug("firewall (noop): #{set} <- #{length(addresses)} entries")
    :ok
  end
end

defmodule QPBX.Firewall.Helper.Socket do
  @moduledoc "Talks to `qpbx-fwd` over its Unix socket: one JSON line out, one back."
  @behaviour QPBX.Firewall.Helper

  @timeout 10_000

  @impl true
  def replace(set, addresses, timeouts) when timeouts == %{},
    do: request(%{op: "replace", set: set, addresses: addresses})

  def replace(set, addresses, timeouts),
    do: request(%{op: "replace", set: set, addresses: addresses, timeouts: timeouts})

  defp request(body) do
    path = Application.get_env(:qpbx, QPBX.Firewall, [])[:socket] || "/run/qpbx-fwd/fwd.sock"

    with {:ok, sock} <-
           :gen_tcp.connect(
             {:local, path},
             0,
             [:binary, active: false, packet: :line, buffer: 65_536],
             @timeout
           ) do
      try do
        with :ok <- :gen_tcp.send(sock, [Jason.encode!(body), "\n"]),
             {:ok, line} <- :gen_tcp.recv(sock, 0, @timeout) do
          case Jason.decode(line) do
            {:ok, %{"ok" => true}} -> :ok
            {:ok, %{"error" => error}} -> {:error, error}
            _ -> {:error, :bad_response}
          end
        end
      after
        :gen_tcp.close(sock)
      end
    end
  end
end
