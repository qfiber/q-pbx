defmodule QPBX.Web.KamailioController do
  @moduledoc """
  Kamailio's registration reports (`POST /internal/kamailio/registration`, JSON). Only from
  this server (loopback, not through nginx) and with the shared secret in
  `X-QPBX-Secret`. Always answers quickly: Kamailio sends these without waiting.
  """
  use QPBX.Web, :controller

  def registration(conn, params) do
    if loopback?(conn) and authorized?(conn) do
      case QPBX.Edge.registration_report(params) do
        :ok -> send_resp(conn, 204, "")
        {:error, _} -> send_resp(conn, 422, "")
      end
    else
      send_resp(conn, 403, "")
    end
  end

  defp loopback?(%{remote_ip: {127, _, _, _}}), do: true
  defp loopback?(%{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp loopback?(_), do: false

  defp authorized?(conn) do
    expected = QPBX.Edge.event_secret()

    with true <- is_binary(expected) and byte_size(expected) >= 16,
         [given] <- get_req_header(conn, "x-qpbx-secret") do
      Plug.Crypto.secure_compare(given, expected)
    else
      _ -> false
    end
  end
end
