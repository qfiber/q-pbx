defmodule QPBX.Notify.VoicemailEmail do
  @moduledoc """
  Oban worker: emails a new voicemail, with its audio attached when the mailbox asks for it.
  The job holds the storage file key only; the audio is decrypted while the email is built.
  """
  use Oban.Worker, queue: :notify, max_attempts: 10
  use Gettext, backend: QPBX.Notify.Gettext
  import Swoosh.Email
  alias QPBX.Notify.Mail

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, email} <- build(args),
         {:ok, _} <- Mail.deliver(email) do
      :ok
    else
      # The message was deleted before the email went out: nothing to send.
      {:error, :enoent} -> :discard
      {:error, reason} -> {:error, reason}
    end
  end

  def build(%{"locale" => locale} = a) do
    with {:ok, audio} <- audio(a["file_key"]) do
      email = Gettext.with_locale(QPBX.Notify.Gettext, locale, fn -> message(a) end)
      {:ok, if(audio, do: attach(email, audio, a["format"]), else: email)}
    end
  end

  defp message(a) do
    caller = caller(a)

    text =
      gettext(
        "Extension %{extension} has a new message from %{caller}, %{seconds} seconds long, left at %{at} (UTC).",
        extension: a["extension"],
        caller: caller,
        seconds: a["duration"],
        at: a["at"]
      )

    new()
    |> to(a["email"])
    |> from(Mail.sender())
    |> subject(gettext("New voicemail from %{caller}", caller: caller))
    |> text_body(text <> "\n")
    |> html_body("<p>#{text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()}</p>")
  end

  defp caller(%{"caller" => number, "caller_name" => name})
       when is_binary(name) and name != number,
       do: "#{name} (#{number || gettext("an unknown caller")})"

  defp caller(a), do: a["caller"] || gettext("an unknown caller")

  defp attach(email, audio, format) do
    attachment(
      email,
      Swoosh.Attachment.new({:data, audio},
        filename: "voicemail.#{format}",
        content_type: mime(format)
      )
    )
  end

  defp audio(nil), do: {:ok, nil}
  defp audio(key), do: QPBX.Storage.get(key)

  defp mime("wav"), do: "audio/wav"
  defp mime(_), do: "audio/mpeg"
end
