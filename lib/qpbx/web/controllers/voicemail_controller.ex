defmodule QPBX.Web.VoicemailController do
  @moduledoc "A voicemail message's audio, decrypted for a signed-in tenant admin of its tenant."
  use QPBX.Web, :controller
  alias QPBX.Core.User

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  # The content type is one of two audio types, never from the request; nosniff is set.
  def audio(conn, %{"id" => id}) do
    with "tenant_admin" <- User.role(conn.assigns.current_account),
         {:ok, audio, format} <- QPBX.Telephony.voicemail_audio(conn.assigns.current_scope, id) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type(if(format == "wav", do: "audio/wav", else: "audio/mpeg"), nil)
      |> send_resp(200, audio)
    else
      _ -> conn |> put_status(404) |> text("Not found")
    end
  end
end
