defmodule QPBX.Web.PromptController do
  @moduledoc """
  Prompt audio for the prompts page (tenant admins): a recording of the tenant's library, or
  one of the offered system prompts (only those, read from the installed sound set).
  """
  use QPBX.Web, :controller
  alias QPBX.Core.User

  plug :tenant_admin

  defp tenant_admin(conn, _) do
    if User.role(conn.assigns.current_account) == "tenant_admin",
      do: conn,
      else: conn |> put_status(404) |> text("Not found") |> halt()
  end

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  # The content type is one of two audio types, never from the request; nosniff is set.
  def audio(conn, %{"id" => id}) do
    case QPBX.Telephony.prompt_audio(conn.assigns.current_scope, id) do
      {:ok, audio, format} -> send_audio(conn, audio, format)
      _ -> conn |> put_status(404) |> text("Not found")
    end
  end

  # sobelow_skip ["Traversal.FileModule", "XSS.SendResp"]
  # Only paths in the fixed system list are read (no traversal); they sit under the sound set.
  def system(conn, %{"path" => path}) do
    with true <- QPBX.Telephony.system_prompt?(path),
         {:ok, audio} <- File.read(system_file(path)) do
      send_audio(conn, audio, "wav")
    else
      _ -> conn |> put_status(404) |> text("Not found")
    end
  end

  # "ivr/ivr-x.wav" is stored as "ivr/8000/ivr-x.wav" (one folder per sample rate).
  defp system_file(path) do
    [dir, file] = String.split(path, "/", parts: 2)

    Path.join([
      Application.get_env(:qpbx, :sounds_dir, "/usr/share/qpbx/sounds/en/us/callie"),
      dir,
      "8000",
      file
    ])
  end

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  # The content type is one of two audio types, never from the request; nosniff is set.
  defp send_audio(conn, audio, format) do
    conn
    |> put_resp_header("cache-control", "private, max-age=300")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type(if(format == "wav", do: "audio/wav", else: "audio/mpeg"), nil)
    |> send_resp(200, audio)
  end
end
