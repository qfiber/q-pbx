defmodule QPBX.Telephony.VoicemailFlow do
  @moduledoc """
  Voicemail on a call, driven by the call process: leaving a message (greeting, tone, record,
  store) and the mailbox menu (`*97`: PIN, counts, each message with 7 delete, 9 or # save and
  next, 5 repeat). Pure steps: each returns the FreeSWITCH applications to run in order
  (`{app, arg}`) and the new state; the call process sends them and calls `next/2` with the
  last one's CHANNEL_EXECUTE_COMPLETE. Plain audio exists only in the temporary folder, and
  only while it plays (`cleanup/1`).
  """
  require Logger
  alias QPBX.Storage
  alias QPBX.Telephony.Voicemail

  @max_seconds 180
  @pin_tries 3
  @goodbye "voicemail/vm-goodbye.wav"

  ## Leaving a message

  @doc "`info`: caller_number, caller_name, extension_number, locale, reason (busy | unavailable)."
  def leave(mailbox, info) do
    vm = %{mode: :leave, mailbox: mailbox, info: info, step: :record, temp: [], record: nil}
    {greeting, vm} = greeting(vm)
    path = path("mp3")

    {[
       {"answer", ""},
       {"sleep", "500"},
       {"playback", greeting},
       {"playback", "tone_stream://%(400,0,800)"},
       {"set", "playback_terminators=#"},
       {"record", "#{path} #{@max_seconds} 200 5"}
     ], %{vm | record: {path, now()}}}
  end

  defp greeting(vm) do
    case Voicemail.greeting_system(vm.mailbox, vm.info.reason) do
      nil -> {default_greeting(vm.info.extension_number), vm}
      g -> temp(vm, g.file_key, g.format)
    end
  end

  # "The person at extension 1 0 1 is not available. Record your message at the tone..."
  defp default_greeting(number) do
    digits = for d <- String.graphemes(number || ""), do: "digits/#{d}.wav"

    files(
      ["voicemail/vm-person.wav"] ++
        digits ++ ["voicemail/vm-not_available.wav", "voicemail/vm-record_message.wav"]
    )
  end

  ## The mailbox menu

  def menu(mailbox) do
    vm = %{mode: :menu, mailbox: mailbox, step: {:pin, 1}, temp: [], messages: [], record: nil}
    {[{"answer", ""}, {"sleep", "500"}, pin_prompt(1)], vm}
  end

  defp pin_prompt(n),
    do:
      {"play_and_get_digits",
       "4 10 1 6000 # voicemail/vm-enter_pass.wav silence_stream://250 qpbx_vm_pin#{n} \\d+"}

  ## Steps

  @doc "The last application finished; returns `{apps, vm}` (apps empty: nothing more to do)."
  def next(e, %{step: :record} = vm) do
    store(vm, e)
    {[{"playback", @goodbye}, {"hangup", "NORMAL_CLEARING"}], %{vm | step: :done, record: nil}}
  end

  def next(e, %{step: {:pin, n}} = vm) do
    cond do
      Voicemail.pin_ok?(vm.mailbox, e["variable_qpbx_vm_pin#{n}"]) ->
        intro(vm)

      n < @pin_tries ->
        {[{"playback", "voicemail/vm-fail_auth.wav"}, pin_prompt(n + 1)],
         %{vm | step: {:pin, n + 1}}}

      true ->
        Logger.warning("voicemail: wrong PIN #{@pin_tries} times for mailbox #{vm.mailbox.id}")

        {[
           {"playback", "voicemail/vm-fail_auth.wav"},
           {"playback", @goodbye},
           {"hangup", "NORMAL_CLEARING"}
         ], %{vm | step: :done}}
    end
  end

  def next(e, %{step: {:message, i}} = vm) do
    vm = cleanup(vm)
    msg = Enum.at(vm.messages, i)

    case e["variable_qpbx_vm_key#{i}"] do
      "5" ->
        play(vm, i)

      "7" ->
        Voicemail.delete_system(msg)
        {apps, vm} = play(vm, i + 1)
        {[{"playback", "voicemail/vm-deleted.wav"} | apps], vm}

      _ ->
        if msg.folder == "new", do: Voicemail.saved_system(msg)
        play(vm, i + 1)
    end
  end

  def next(_e, vm), do: {[], vm}

  defp intro(vm) do
    messages = Voicemail.messages_system(vm.mailbox)
    new = Enum.count(messages, &(&1.folder == "new"))
    vm = %{vm | messages: messages}

    {apps, vm} = play(vm, 0)

    {[
       {"playback", "voicemail/vm-you_have.wav"},
       {"say", "en number pronounced #{new}"},
       {"playback", files(["voicemail/vm-new.wav", "voicemail/vm-messages.wav"])} | apps
     ], vm}
  end

  defp play(vm, i) when i >= length(vm.messages),
    do:
      {[
         {"playback", "voicemail/vm-no_more_messages.wav"},
         {"playback", @goodbye},
         {"hangup", "NORMAL_CLEARING"}
       ], %{vm | step: :done}}

  defp play(vm, i) do
    msg = Enum.at(vm.messages, i)

    case temp(vm, msg.file_key, msg.format) do
      {nil, vm} ->
        # Audio missing from storage: skip it rather than end the session.
        play(vm, i + 1)

      {path, vm} ->
        options =
          files(~w(voicemail/vm-delete_message.wav voicemail/vm-press.wav digits/7.wav
                   voicemail/vm-save_message.wav voicemail/vm-press.wav digits/9.wav
                   voicemail/vm-repeat_message.wav voicemail/vm-press.wav digits/5.wav))

        {[
           {"playback", path},
           {"play_and_get_digits",
            "1 1 1 6000 # #{options} silence_stream://250 qpbx_vm_key#{i} [579#]"}
         ], %{vm | step: {:message, i}}}
    end
  end

  ## Recording and files

  @doc "The call ended: a message being recorded is kept; temporary audio is removed."
  def hangup(%{step: :record} = vm, e) do
    store(vm, e)
    cleanup(%{vm | step: :done, record: nil})
  end

  def hangup(vm, _e), do: cleanup(vm)

  # sobelow_skip ["Traversal.FileModule"]
  # The recording path was made by path/1 (temporary folder and a fresh UUID).
  defp store(%{record: {path, started}} = vm, e) do
    seconds = duration(e, started)

    with true <- seconds >= 1,
         {:ok, audio} <- File.read(path),
         true <- byte_size(audio) > 0 do
      info = Map.take(vm.info, [:caller_number, :caller_name, :extension_number, :locale])

      Voicemail.store_system(
        vm.mailbox,
        audio,
        Map.merge(info, %{duration: seconds, format: "mp3"})
      )
    else
      _ -> Logger.info("voicemail: nothing recorded for mailbox #{vm.mailbox.id}")
    end
  rescue
    err -> Logger.error("voicemail: message not stored: #{Exception.message(err)}")
  after
    File.rm(path)
  end

  defp store(_vm, _e), do: :ok

  defp duration(e, started) do
    case Integer.parse(e["variable_record_seconds"] || "") do
      {s, _} -> s
      :error -> DateTime.diff(now(), started)
    end
  end

  def cleanup(vm) do
    Enum.each(vm.temp, &Storage.discard/1)
    %{vm | temp: []}
  end

  defp temp(vm, key, format) do
    case Storage.decrypt_to_temp(key, format) do
      {:ok, path} -> {path, %{vm | temp: [path | vm.temp]}}
      _ -> {nil, vm}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp path(ext) do
    File.mkdir_p!(Storage.temp_dir())
    Path.join(Storage.temp_dir(), "rec-#{Ecto.UUID.generate()}.#{ext}")
  end

  defp files([one]), do: one
  defp files(list), do: "file_string://" <> Enum.join(list, "!")
  defp now, do: DateTime.utc_now()
end
