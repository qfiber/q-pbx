defmodule QPBX.Web.Api.PromptController do
  @moduledoc "The tenant's prompt library: list, upload (MP3 or WAV), audio, delete; the system prompts."
  use QPBX.Web, :api_controller
  alias QPBX.Telephony
  alias QPBX.Telephony.Prompt

  @prompt Schemas.of(Prompt, "Prompt")
  @audio_types ["audio/mpeg", "audio/wav"]

  def operation(:index),
    do: op("Prompts", "The prompt library, by name", "read", :tenant, response: {:list, @prompt})

  def operation(:create),
    do:
      op(
        "Prompts",
        "Upload a recording (the name in ?name=); MP3 or WAV, up to 5 MB",
        "write",
        :tenant,
        params: [query("name", "the prompt's name, unique in the tenant", %{type: "string"})],
        body: {:binary, @audio_types},
        response: @prompt,
        status: 201
      )

  def operation(:audio),
    do: op("Prompts", "A recording's audio", "read", :tenant, response: {:binary, "audio/wav"})

  def operation(:delete),
    do: op("Prompts", "Remove a recording", "write", :tenant, response: nil)

  def operation(:system),
    do:
      op(
        "Prompts",
        "The system prompts that can be used like recordings (their path is the reference)",
        "read",
        :tenant,
        response: {:list, %{type: "object", properties: %{path: %{type: "string"}}}}
      )

  def index(conn, params), do: paged(conn, Telephony.list_prompts(scope(conn)), params)

  def create(conn, %{"name" => name}) when is_binary(name) and name != "" do
    case read_body(conn, length: 5_000_001) do
      {:ok, audio, conn} ->
        conn
        |> reply(Telephony.upload_prompt(scope(conn), name, audio, conn.assigns.api_key), 201)

      {:more, _, conn} ->
        reply(conn, {:error, :too_large})

      {:error, _} ->
        reply(conn, {:error, {:bad_request, "the audio could not be read"}})
    end
  end

  def create(conn, _), do: reply(conn, {:error, {:bad_request, "name is required"}})

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  # The content type is one of two audio types, never from the request; nosniff is set.
  def audio(conn, %{"id" => id}) do
    case Telephony.prompt_audio(scope(conn), id) do
      {:ok, audio, format} ->
        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_content_type(if(format == "wav", do: "audio/wav", else: "audio/mpeg"), nil)
        |> send_resp(200, audio)

      _ ->
        reply(conn, {:error, :not_found})
    end
  end

  def delete(conn, %{"id" => id}),
    do: reply(conn, Telephony.delete_prompt(scope(conn), id, conn.assigns.api_key), 204)

  def system(conn, _),
    do:
      json(conn, %{
        data: for({path, _} <- Telephony.system_prompts(), do: %{path: path}),
        next_cursor: nil
      })

  defp scope(conn), do: conn.assigns.current_scope
end
