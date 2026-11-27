defmodule QPBX.Telephony.Voicemail do
  @moduledoc """
  Mailboxes (one per extension), greetings and messages. Audio is encrypted in
  `QPBX.Storage`; rows keep the file key. Tenant-facing functions take the request's scope (row
  level security in force); the `*_system` ones serve call processes. Every change of an
  extension's counts announces `VoicemailChanged` (message-waiting light); a new message also
  `VoicemailReceived`, and an email with the audio when the mailbox has an address.
  """
  import Ecto.Query
  require Logger
  alias QPBX.{Core, Events, Repo, Storage}
  alias QPBX.Core.Scope
  alias QPBX.Events.{VoicemailChanged, VoicemailReceived}
  alias QPBX.Telephony.Voicemail.{Greeting, Mailbox, Message}

  @max_greeting_bytes 5_000_000

  ## Tenant admins (portal)

  def mailbox(%Scope{kind: :tenant, tenant_id: tid} = scope, ext_id) do
    Scope.run(scope, fn ->
      Repo.get_by(Mailbox, tenant_id: tid, extension_id: ext_id) ||
        %Mailbox{tenant_id: tid, extension_id: ext_id}
    end)
  end

  def change_mailbox(%Mailbox{} = mb, attrs \\ %{}), do: Mailbox.changeset(mb, attrs)

  def save_mailbox(%Scope{kind: :tenant, tenant_id: tid} = scope, ext_id, attrs, actor) do
    Scope.run(scope, fn ->
      mb =
        Repo.get_by(Mailbox, tenant_id: tid, extension_id: ext_id) ||
          %Mailbox{tenant_id: tid, extension_id: ext_id}

      with {:ok, saved} <- mb |> Mailbox.changeset(attrs) |> Repo.insert_or_update() do
        Core.audit(actor, "mailbox.update", nil, %{
          tenant_id: tid,
          extension_id: ext_id,
          enabled: saved.enabled
        })

        {:ok, saved}
      end
    end)
  end

  @doc """
  Deletes an extension's mailbox with its messages and greetings, files included. Call it
  before deleting the extension: the database cascade would remove the rows but not the files.
  """
  def delete_mailbox(%Scope{kind: :tenant, tenant_id: tid} = scope, ext_id, actor) do
    keys =
      Scope.run(scope, fn ->
        case Repo.get_by(Mailbox, tenant_id: tid, extension_id: ext_id) do
          nil ->
            []

          mb ->
            keys =
              Repo.all(from v in Message, where: v.mailbox_id == ^mb.id, select: v.file_key) ++
                Repo.all(from g in Greeting, where: g.mailbox_id == ^mb.id, select: g.file_key)

            Repo.delete!(mb)
            Core.audit(actor, "mailbox.delete", nil, %{tenant_id: tid, extension_id: ext_id})
            keys
        end
      end)

    Enum.each(keys, &Storage.delete/1)
    :ok
  end

  @doc "The tenant's messages, newest first, each with its mailbox's extension id."
  def list_messages(%Scope{kind: :tenant, tenant_id: tid} = scope) do
    Scope.run(scope, fn ->
      Repo.all(
        from v in Message,
          join: m in Mailbox,
          on: m.id == v.mailbox_id,
          where: v.tenant_id == ^tid,
          order_by: [desc: v.inserted_at],
          select: {v, m.extension_id}
      )
    end)
  end

  @doc "A message's audio: `{:ok, binary, format}`."
  def message_audio(%Scope{kind: :tenant} = scope, id) do
    with %Message{} = v <- get_message(scope, id),
         {:ok, audio} <- Storage.get(v.file_key) do
      {:ok, audio, v.format}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def mark_saved(%Scope{kind: :tenant} = scope, id, actor) do
    with %Message{} = v <- get_message(scope, id) do
      Core.audit(actor, "voicemail.save", nil, %{tenant_id: v.tenant_id, voicemail_id: v.id})
      set_folder(v, "saved")
    end
  end

  def delete_message(%Scope{kind: :tenant} = scope, id, actor) do
    with %Message{} = v <- get_message(scope, id) do
      Core.audit(actor, "voicemail.delete", nil, %{tenant_id: v.tenant_id, voicemail_id: v.id})
      remove(v)
    end
  end

  defp get_message(%Scope{tenant_id: tid} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Scope.run(scope, fn -> Repo.get_by(Message, id: id, tenant_id: tid) end)
      :error -> nil
    end
  end

  @doc "Greeting kinds present for an extension's mailbox."
  def greetings(%Scope{kind: :tenant, tenant_id: tid} = scope, ext_id) do
    Scope.run(scope, fn ->
      Repo.all(
        from g in Greeting,
          join: m in Mailbox,
          on: m.id == g.mailbox_id,
          where: m.tenant_id == ^tid and m.extension_id == ^ext_id,
          select: g.kind
      )
    end)
  end

  @doc "Stores an uploaded greeting (MP3 or WAV, up to 5 MB) for a mailbox that exists."
  def put_greeting(%Scope{kind: :tenant} = scope, ext_id, kind, audio, actor)
      when is_binary(audio) do
    with true <- kind in Greeting.kinds() || {:error, :bad_kind},
         true <- byte_size(audio) <= @max_greeting_bytes || {:error, :too_large},
         format when is_binary(format) <- audio_format(audio) || {:error, :not_audio},
         %Mailbox{id: mid} when not is_nil(mid) <- mailbox(scope, ext_id) do
      replace_greeting(scope, mid, ext_id, kind, audio, format, actor)
    else
      %Mailbox{} -> {:error, :no_mailbox}
      error -> error
    end
  end

  # The new greeting replaces the old one; the old file goes once the row is gone.
  defp replace_greeting(%Scope{tenant_id: tid} = scope, mid, ext_id, kind, audio, format, actor) do
    {:ok, key} = Storage.put("voicemail", audio)

    old =
      Scope.run(scope, fn ->
        old = Repo.get_by(Greeting, mailbox_id: mid, kind: kind)
        if old, do: Repo.delete!(old)

        greeting = %Greeting{
          tenant_id: tid,
          mailbox_id: mid,
          kind: kind,
          file_key: key,
          format: format
        }

        Repo.insert!(greeting)

        Core.audit(actor, "greeting.update", nil, %{
          tenant_id: tid,
          extension_id: ext_id,
          kind: kind
        })

        old
      end)

    if old, do: Storage.delete(old.file_key), else: :ok
  end

  def delete_greeting(%Scope{kind: :tenant, tenant_id: tid} = scope, ext_id, kind, actor) do
    %Mailbox{id: mid} = mailbox(scope, ext_id)

    case mid && Scope.run(scope, fn -> Repo.get_by(Greeting, mailbox_id: mid, kind: kind) end) do
      %Greeting{} = g ->
        Scope.run(scope, fn -> Repo.delete!(g) end)
        Storage.delete(g.file_key)

        Core.audit(actor, "greeting.delete", nil, %{
          tenant_id: tid,
          extension_id: ext_id,
          kind: kind
        })

        :ok

      _ ->
        :ok
    end
  end

  @doc "mp3 or wav, by the file's own header (never by its name)."
  def audio_format(<<"RIFF", _::binary-4, "WAVE", _::binary>>), do: "wav"
  def audio_format(<<"ID3", _::binary>>), do: "mp3"
  def audio_format(<<0xFF, b, _::binary>>) when Bitwise.band(b, 0xE0) == 0xE0, do: "mp3"
  def audio_format(_), do: nil

  ## Call processes

  @doc "The enabled mailbox of an extension, or nil."
  def mailbox_system(tenant_id, ext_id) do
    {:ok, mb} =
      Core.with_tenant(tenant_id, fn ->
        Repo.get_by(Mailbox, tenant_id: tenant_id, extension_id: ext_id, enabled: true)
      end)

    mb
  end

  @doc "The greeting to play: temporary if set, else the one for `reason` (busy | unavailable)."
  def greeting_system(%Mailbox{id: mid, tenant_id: tid}, reason) do
    {:ok, gs} =
      Core.with_tenant(tid, fn -> Repo.all(from g in Greeting, where: g.mailbox_id == ^mid) end)

    Enum.find(gs, &(&1.kind == "temporary")) || Enum.find(gs, &(&1.kind == to_string(reason)))
  end

  def pin_ok?(mb, pin), do: Mailbox.pin_ok?(mb, pin)

  @doc "Messages for the phone menu: new first (oldest first), then saved."
  def messages_system(%Mailbox{id: mid, tenant_id: tid}) do
    {:ok, list} =
      Core.with_tenant(tid, fn ->
        Repo.all(
          from v in Message,
            where: v.mailbox_id == ^mid,
            order_by: [desc: v.folder == "new", asc: v.inserted_at]
        )
      end)

    list
  end

  def saved_system(%Message{} = v), do: set_folder(v, "saved")
  def delete_system(%Message{} = v), do: remove(v)

  @doc """
  Stores a recorded message (plain audio from FreeSWITCH) and tells everyone about it: the
  light, the event, the email. `info`: caller_number, caller_name, duration, format, locale,
  extension_number.
  """
  def store_system(%Mailbox{} = mb, audio, info) do
    {:ok, key} = Storage.put("voicemail", audio)

    {:ok, v} =
      Core.with_tenant(mb.tenant_id, fn ->
        Repo.insert!(%Message{
          tenant_id: mb.tenant_id,
          mailbox_id: mb.id,
          caller_number: info[:caller_number],
          caller_name: info[:caller_name],
          duration: info.duration,
          file_key: key,
          format: info.format
        })
      end)

    Events.publish(%VoicemailReceived{
      tenant_id: mb.tenant_id,
      voicemail_id: v.id,
      extension_id: mb.extension_id,
      caller_number: v.caller_number,
      caller_name: v.caller_name,
      duration: v.duration,
      at: v.inserted_at
    })

    announce_counts(mb.tenant_id, mb.id)

    if mb.email do
      QPBX.Notify.deliver_voicemail(%{
        email: mb.email,
        locale: info[:locale] || "en",
        extension: info[:extension_number],
        caller: v.caller_number,
        caller_name: v.caller_name,
        duration: v.duration,
        at: v.inserted_at,
        file_key: if(mb.attach_audio, do: key),
        format: v.format
      })
    end

    {:ok, v}
  end

  @doc "New and saved counts per extension id, of one tenant or of all (lights refresh)."
  def counts(tenant_id \\ nil) do
    q =
      from v in Message,
        join: m in Mailbox,
        on: m.id == v.mailbox_id,
        group_by: m.extension_id,
        select:
          {m.extension_id,
           {count(fragment("CASE WHEN ? = 'new' THEN 1 END", v.folder)),
            count(fragment("CASE WHEN ? = 'saved' THEN 1 END", v.folder))}}

    q = if tenant_id, do: where(q, [v], v.tenant_id == ^tenant_id), else: q
    Map.new(Repo.all(q))
  end

  ## Shared

  defp set_folder(%Message{} = v, folder) do
    {:ok, v} =
      Core.with_tenant(v.tenant_id, fn ->
        v |> Ecto.Changeset.change(folder: folder) |> Repo.update!()
      end)

    announce_counts(v.tenant_id, v.mailbox_id)
    {:ok, v}
  end

  defp remove(%Message{} = v) do
    {:ok, _} = Core.with_tenant(v.tenant_id, fn -> Repo.delete!(v) end)
    Storage.delete(v.file_key)
    announce_counts(v.tenant_id, v.mailbox_id)
    :ok
  end

  defp announce_counts(tid, mailbox_id) do
    {:ok, {ext_id, new, saved}} =
      Core.with_tenant(tid, fn ->
        ext_id = Repo.one!(from m in Mailbox, where: m.id == ^mailbox_id, select: m.extension_id)

        [new, saved] =
          for f <- ~w(new saved),
              do:
                Repo.aggregate(
                  from(v in Message, where: v.mailbox_id == ^mailbox_id and v.folder == ^f),
                  :count
                )

        {ext_id, new, saved}
      end)

    Events.publish(%VoicemailChanged{
      tenant_id: tid,
      extension_id: ext_id,
      new: new,
      saved: saved,
      at: DateTime.utc_now()
    })
  end
end
