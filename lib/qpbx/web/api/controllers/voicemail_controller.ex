defmodule QPBX.Web.Api.VoicemailController do
  @moduledoc """
  Voicemail (tenant keys): an extension's mailbox and greetings, and the messages. A message's
  audio is fetched through a link valid for 5 minutes (`audio_link`), so programs and
  browsers can play it without holding the key.
  """
  use QPBX.Web, :api_controller
  alias QPBX.{Core, Telephony}
  alias QPBX.Telephony.Voicemail.{Greeting, Mailbox, Message}

  @link_age 300
  @mailbox Schemas.of(Mailbox, "Mailbox")
  @message Schemas.of(Message, "Voicemail")
  @audio_types ["audio/mpeg", "audio/wav"]

  def operation(:mailbox),
    do: op("Voicemail", "An extension's mailbox", "read", :tenant, response: @mailbox)

  def operation(:put_mailbox),
    do:
      op("Voicemail", "Set up or change an extension's mailbox", "write", :tenant,
        body:
          Schemas.input(Mailbox, "MailboxInput", [], %{
            pin: %{type: "string", writeOnly: true, description: "4 to 10 digits"}
          }),
        response: @mailbox
      )

  def operation(:delete_mailbox),
    do:
      op("Voicemail", "Delete a mailbox with its messages and greetings", "write", :tenant,
        response: nil
      )

  def operation(:greetings),
    do:
      op("Voicemail", "Greetings an extension has recorded", "read", :tenant,
        response: {:list, %{type: "string", enum: Greeting.kinds()}}
      )

  def operation(:put_greeting),
    do:
      op(
        "Voicemail",
        "Upload a greeting (kind: #{Enum.join(Greeting.kinds(), ", ")}); MP3 or WAV, up to 5 MB",
        "write",
        :tenant,
        body: {:binary, @audio_types},
        response: nil
      )

  def operation(:delete_greeting),
    do: op("Voicemail", "Delete a greeting", "write", :tenant, response: nil)

  def operation(:index),
    do:
      op("Voicemail", "Messages, newest first", "read", :tenant,
        params:
          Page.params() ++
            [query("extension_id", "one extension's messages", %{type: "string", format: "uuid"})],
        response: {:list, @message}
      )

  def operation(:save),
    do:
      op("Voicemail", "Mark a message heard (moves it to saved)", "write", :tenant, response: nil)

  def operation(:delete),
    do: op("Voicemail", "Delete a message and its audio", "write", :tenant, response: nil)

  def operation(:audio_link),
    do:
      op(
        "Voicemail",
        "A link to the message's audio, valid #{div(@link_age, 60)} minutes, needing no key",
        "read",
        :tenant,
        response:
          {:raw,
           %{
             type: "object",
             properties: %{
               url: %{type: "string"},
               expires_at: %{type: "string", format: "date-time"}
             }
           }}
      )

  def mailbox(conn, %{"extension_id" => id}),
    do: data(conn, Telephony.mailbox(scope(conn), ext!(conn, id)))

  def put_mailbox(conn, %{"extension_id" => id} = p),
    do:
      reply(
        conn,
        Telephony.save_mailbox(
          scope(conn),
          ext!(conn, id),
          Map.drop(p, ["extension_id"]),
          actor(conn)
        )
      )

  def delete_mailbox(conn, %{"extension_id" => id}),
    do: reply(conn, Telephony.delete_mailbox(scope(conn), ext!(conn, id), actor(conn)))

  def greetings(conn, %{"extension_id" => id}) do
    kinds = Telephony.greetings(scope(conn), ext!(conn, id))
    json(conn, %{data: Schemas.render(kinds), next_cursor: nil})
  end

  def put_greeting(conn, %{"extension_id" => id, "kind" => kind}) do
    ext_id = ext!(conn, id)

    case read_body(conn, length: 5_000_001) do
      {:ok, audio, conn} ->
        reply(conn, Telephony.put_greeting(scope(conn), ext_id, kind, audio, actor(conn)))

      {:more, _, conn} ->
        reply(conn, {:error, :too_large})

      {:error, _} ->
        reply(conn, {:error, {:bad_request, "the audio could not be read"}})
    end
  end

  def delete_greeting(conn, %{"extension_id" => id, "kind" => kind}),
    do: reply(conn, Telephony.delete_greeting(scope(conn), ext!(conn, id), kind, actor(conn)))

  def index(conn, params) do
    ext_id = if e = params["extension_id"], do: ext!(conn, e)

    messages =
      for {message, ext} <- Telephony.list_voicemails(scope(conn), ext_id),
          do:
            message |> Schemas.render() |> Map.put(:extension_id, ext) |> Map.put(:id, message.id)

    paged(conn, messages, params)
  end

  def save(conn, %{"id" => id}),
    do: reply(conn, Telephony.save_voicemail(scope(conn), id, actor(conn)), 204)

  def delete(conn, %{"id" => id}),
    do: reply(conn, Telephony.delete_voicemail(scope(conn), id, actor(conn)), 204)

  def audio_link(conn, %{"id" => id}) do
    case Telephony.voicemail_audio(scope(conn), id) do
      {:ok, _, _} ->
        token = Phoenix.Token.sign(conn, "voicemail-audio", {scope(conn).tenant_id, id})
        expires = DateTime.add(DateTime.utc_now(), @link_age) |> DateTime.truncate(:second)
        json(conn, %{url: url(~p"/v1/voicemail-audio/#{token}"), expires_at: expires})

      error ->
        reply(conn, error)
    end
  end

  @doc "Max age of an audio link, for `QPBX.Web.Api.VoicemailAudioController`."
  def link_age, do: @link_age

  defp ext!(conn, id), do: Core.get_extension!(scope(conn), id).id
  defp scope(conn), do: conn.assigns.current_scope
  defp actor(conn), do: conn.assigns.api_key
end
