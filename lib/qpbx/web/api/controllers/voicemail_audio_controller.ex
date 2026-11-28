defmodule QPBX.Web.Api.VoicemailAudioController do
  @moduledoc """
  `GET /v1/voicemail-audio/:token`: a message's audio for a link from `audio_link` (signed,
  5 minutes, one tenant's one message). No key: the link is the permission.
  """
  use QPBX.Web, :controller
  alias QPBX.Web.Api.{Error, VoicemailController}

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  # The content type is one of two audio types, never from the request; nosniff is set.
  def show(conn, %{"token" => token}) do
    with {:ok, {tid, id}} <-
           Phoenix.Token.verify(conn, "voicemail-audio", token,
             max_age: VoicemailController.link_age()
           ),
         {:ok, audio, format} <-
           QPBX.Telephony.voicemail_audio(%QPBX.Core.Scope{kind: :tenant, tenant_id: tid}, id) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type(if(format == "wav", do: "audio/wav", else: "audio/mpeg"), nil)
      |> send_resp(200, audio)
    else
      _ -> Error.send(conn, 404, "not_found", "This link is not valid or has expired.")
    end
  end
end
