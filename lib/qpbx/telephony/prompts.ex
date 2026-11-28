defmodule QPBX.Telephony.Prompts do
  @moduledoc """
  A tenant's prompt library: recordings that IVRs, ring groups and the like play to callers.
  WAV or MP3 as uploaded (FreeSWITCH plays both: `mod_sndfile`, `mod_shout`), up to 5 MB,
  encrypted in storage. Beside them, a short list of the installed English system prompts
  (`system/0`), referred to by their path ("ivr/ivr-thank_you_for_calling.wav"); the full
  sound set also holds prompts no business would play, so only these are offered.
  """
  import Ecto.Query
  alias QPBX.Core.Scope
  alias QPBX.{Repo, Storage}
  alias QPBX.Telephony.{Prompt, Voicemail}

  @max_bytes 5_000_000

  @system [
    {"ivr/ivr-thank_you_for_calling.wav", :thank_you_for_calling},
    {"ivr/ivr-thank_you.wav", :thank_you},
    {"ivr/ivr-one_moment_please.wav", :one_moment},
    {"ivr/ivr-please_hold_while_party_contacted.wav", :hold_while_contacted},
    {"ivr/ivr-hold_connect_call.wav", :hold_connect},
    {"ivr/ivr-stay_on_line_call_answered_momentarily.wav", :stay_on_line},
    {"ivr/ivr-thank_you_for_holding.wav", :thank_you_for_holding},
    {"ivr/ivr-longer_than_usual_hold_times.wav", :longer_hold_times},
    {"ivr/ivr-call_being_transferred.wav", :being_transferred},
    {"ivr/ivr-enter_ext.wav", :enter_extension},
    {"ivr/ivr-please_enter_extension_followed_by_pound.wav", :enter_extension_pound},
    {"ivr/ivr-that_was_an_invalid_entry.wav", :invalid_entry},
    {"ivr/ivr-invalid_extension_try_again.wav", :invalid_extension},
    {"ivr/ivr-please_try_again.wav", :try_again},
    {"ivr/ivr-to_repeat_these_options.wav", :repeat_options},
    {"ivr/ivr-to_return_to_previous_menu.wav", :previous_menu},
    {"ivr/ivr-for_other_options.wav", :other_options},
    {"ivr/ivr-im_sorry.wav", :sorry},
    {"voicemail/vm-goodbye.wav", :goodbye}
  ]

  @doc "The system prompts offered: `{path, key}` (the portal names each key)."
  def system, do: @system

  @doc "True for a path in the offered list (the only system files the portal will play)."
  def system?(path), do: List.keymember?(@system, path, 0)

  def list(%Scope{kind: :tenant, tenant_id: tid} = scope),
    do:
      Scope.run(scope, fn ->
        Repo.all(from p in Prompt, where: p.tenant_id == ^tid, order_by: p.name)
      end)

  def get(%Scope{kind: :tenant, tenant_id: tid} = scope, id),
    do: Scope.run(scope, fn -> Repo.get_by(Prompt, id: id, tenant_id: tid) end)

  @doc "Adds a recording under `name` (unique per tenant). `{:ok, prompt}` or an error."
  def upload(%Scope{kind: :tenant, tenant_id: tid} = scope, name, audio, actor)
      when is_binary(audio) do
    with true <- byte_size(audio) <= @max_bytes || {:error, :too_large},
         format when is_binary(format) <- Voicemail.audio_format(audio) || {:error, :not_audio} do
      {:ok, key} = Storage.put("prompts", audio)
      attrs = %{name: name, file_key: key, format: format, size: byte_size(audio)}
      Scope.run(scope, fn -> insert(tid, attrs, actor) end) |> drop_file_on_error(key)
    end
  end

  # A row that could not be saved leaves no file behind.
  defp drop_file_on_error({:ok, _} = ok, _key), do: ok

  defp drop_file_on_error(error, key) do
    Storage.delete(key)
    error
  end

  defp insert(tid, attrs, actor) do
    Repo.transaction(fn ->
      with {:ok, p} <- Repo.insert(Prompt.changeset(%Prompt{tenant_id: tid}, attrs)),
           {:ok, _} <- QPBX.Core.audit(actor, "prompt.create", p, %{name: p.name}) do
        p
      else
        {:error, e} -> Repo.rollback(e)
      end
    end)
  end

  @doc "Removes a recording and its file."
  def delete(%Scope{kind: :tenant} = scope, id, actor) do
    with %Prompt{} = p <- get(scope, id) || {:error, :not_found},
         {:ok, _} <- Scope.run(scope, fn -> remove(p, actor) end) do
      Storage.delete(p.file_key)
      {:ok, p}
    end
  end

  defp remove(p, actor) do
    Repo.transaction(fn ->
      Repo.delete!(p)
      QPBX.Core.audit(actor, "prompt.delete", p, %{name: p.name})
    end)
  end

  @doc "A recording's audio: `{:ok, bytes, format}`."
  def audio(%Scope{kind: :tenant} = scope, id) do
    with %Prompt{} = p <- get(scope, id) || {:error, :not_found},
         {:ok, audio} <- Storage.get(p.file_key),
         do: {:ok, audio, p.format}
  end
end
