defmodule QPBX.Web.VoicemailController do
  @moduledoc """
  A voicemail message's audio, decrypted for a signed-in tenant admin of its tenant, or for the
  tenant user whose own extension it belongs to.
  """
  use QPBX.Web, :controller
  alias QPBX.Core.User

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  # The content type is one of two audio types, never from the request; nosniff is set.
  def audio(conn, %{"id" => id}) do
    %{current_account: me, current_scope: scope} = conn.assigns

    # Admins: any message of the tenant. Users: their own extension's only (none linked: none).
    only =
      if User.role(me) == "tenant_admin",
        do: nil,
        else: (QPBX.Core.my_extension(scope) || %{id: Ecto.UUID.generate()}).id

    case QPBX.Telephony.voicemail_audio(scope, id, only) do
      {:ok, audio, format} ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_content_type(if(format == "wav", do: "audio/wav", else: "audio/mpeg"), nil)
        |> send_resp(200, audio)

      _ ->
        conn |> put_status(404) |> text("Not found")
    end
  end
end
