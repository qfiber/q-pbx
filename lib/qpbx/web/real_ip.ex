defmodule QPBX.Web.RealIP do
  @moduledoc """
  Sets `conn.remote_ip` to the client's address. nginx overwrites `X-Real-IP` with the
  client address (after resolving a trusted CDN's header), and the app listens on localhost
  only, so the header is trusted only when the request comes from a loopback address.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{remote_ip: peer} = conn, _opts) do
    with true <- loopback?(peer),
         [value] <- Plug.Conn.get_req_header(conn, "x-real-ip"),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(String.trim(value))) do
      %{conn | remote_ip: ip}
    else
      _ -> conn
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
