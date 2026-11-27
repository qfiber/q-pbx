defmodule QPBX.Web.FreeswitchController do
  @moduledoc """
  FreeSWITCH's dialplan requests (`mod_xml_curl`). Only from this server (loopback, not through
  nginx: `RealIP` turns a proxied request into the client's address) and with FreeSWITCH's
  password (HTTP basic auth). nginx also refuses `/internal/` from outside.
  """
  use QPBX.Web, :controller

  # sobelow_skip ["XSS.SendResp"]
  # The body is a fixed XML template; nothing from the request is in it.
  def dialplan(conn, params) do
    if loopback?(conn) and authorized?(conn) do
      conn
      |> put_resp_content_type("text/xml")
      |> send_resp(200, QPBX.Telephony.dialplan_xml(params))
    else
      send_resp(conn, 403, "")
    end
  end

  defp loopback?(%{remote_ip: {127, _, _, _}}), do: true
  defp loopback?(%{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp loopback?(_), do: false

  defp authorized?(conn) do
    expected = QPBX.Telephony.curl_password()

    with true <- is_binary(expected) and byte_size(expected) >= 16,
         ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, "freeswitch:" <> given} <- Base.decode64(encoded) do
      Plug.Crypto.secure_compare(given, expected)
    else
      _ -> false
    end
  end
end
