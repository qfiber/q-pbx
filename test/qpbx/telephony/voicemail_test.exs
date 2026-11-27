defmodule QPBX.Telephony.VoicemailTest do
  use QPBX.DataCase, async: false
  use Oban.Testing, repo: QPBX.Repo
  import QPBX.Fixtures
  import Swoosh.TestAssertions
  alias QPBX.{Core, Storage, Telephony}
  alias QPBX.Events.{VoicemailChanged, VoicemailReceived}
  alias QPBX.Telephony.Voicemail

  @actor {:system, "test"}
  @mp3 <<"ID3", 4, 0, 0, 0, 0, 0, 0>> <> :binary.copy(<<0>>, 200)

  setup do
    t = tenant_fixture()
    user = user_fixture(t)
    scope = Core.scope_for(user)
    {:ok, ext} = Core.create_extension(scope, %{number: "101", name: "A"}, @actor)
    %{t: t, scope: scope, ext: ext, user: user}
  end

  test "a mailbox needs a PIN that is not trivial; the PIN is stored hashed", %{
    scope: scope,
    ext: ext,
    user: user
  } do
    assert {:error, cs} = Telephony.save_mailbox(scope, ext.id, %{email: "a@x.test"}, user)
    assert %{pin_hash: ["set a PIN"]} = errors_on(cs)
    assert {:error, cs} = Telephony.save_mailbox(scope, ext.id, %{pin: "1234"}, user)
    assert %{pin: ["too easy to guess"]} = errors_on(cs)
    assert {:error, _} = Telephony.save_mailbox(scope, ext.id, %{pin: "12a4"}, user)
    {:ok, mb} = Telephony.save_mailbox(scope, ext.id, %{pin: "4831", email: "a@x.test"}, user)
    refute mb.pin_hash =~ "4831"
    assert Voicemail.pin_ok?(mb, "4831")
    refute Voicemail.pin_ok?(mb, "4832")
    # Saving again without a PIN keeps it.
    {:ok, mb} = Telephony.save_mailbox(scope, ext.id, %{email: "b@x.test"}, user)
    assert Voicemail.pin_ok?(mb, "4831")
  end

  test "a message: stored encrypted, announced, emailed with the audio; saved and deleted",
       %{t: t, scope: scope, ext: ext, user: user} do
    QPBX.Events.subscribe(VoicemailReceived)
    QPBX.Events.subscribe(VoicemailChanged)
    {:ok, _} = Telephony.save_mailbox(scope, ext.id, %{pin: "4831", email: "a@x.test"}, user)
    mb = Voicemail.mailbox_system(t.id, ext.id)

    {:ok, v} =
      Voicemail.store_system(mb, @mp3, %{
        caller_number: "0501234567",
        caller_name: "Bob",
        duration: 7,
        format: "mp3",
        extension_number: "101",
        locale: "en"
      })

    assert_receive {:event, %VoicemailReceived{voicemail_id: id, extension_id: eid, duration: 7}}
    assert id == v.id and eid == ext.id
    assert_receive {:event, %VoicemailChanged{extension_id: ^eid, new: 1, saved: 0}}
    assert Telephony.voicemail_counts(t.id) == %{ext.id => {1, 0}}
    assert {:ok, @mp3, "mp3"} = Telephony.voicemail_audio(scope, v.id)

    [job] = all_enqueued(worker: QPBX.Notify.VoicemailEmail)
    assert job.args["file_key"] == v.file_key
    refute Map.has_key?(job.args, "audio")
    assert :ok = perform_job(QPBX.Notify.VoicemailEmail, job.args)

    assert_email_sent(fn email ->
      assert email.subject =~ "New voicemail from Bob (0501234567)"
      assert [%{filename: "voicemail.mp3", data: @mp3}] = email.attachments
    end)

    {:ok, _} = Telephony.save_voicemail(scope, v.id, user)
    assert_receive {:event, %VoicemailChanged{new: 0, saved: 1}}
    :ok = Telephony.delete_voicemail(scope, v.id, user)
    assert_receive {:event, %VoicemailChanged{new: 0, saved: 0}}
    assert {:error, :enoent} = Storage.get(v.file_key)
    assert Telephony.list_voicemails(scope) == []
    # The email job of a deleted message has nothing to send.
    assert {:discard, _} = perform_job(QPBX.Notify.VoicemailEmail, job.args) |> discard()
  end

  test "another tenant cannot see or play a message", %{t: t, scope: scope, ext: ext, user: user} do
    {:ok, _} = Telephony.save_mailbox(scope, ext.id, %{pin: "4831"}, user)
    mb = Voicemail.mailbox_system(t.id, ext.id)
    {:ok, v} = Voicemail.store_system(mb, @mp3, %{duration: 3, format: "mp3"})
    other = Core.scope_for(user_fixture(tenant_fixture()))
    assert Telephony.list_voicemails(other) == []
    assert {:error, :not_found} = Telephony.voicemail_audio(other, v.id)
    assert nil == Telephony.delete_voicemail(other, v.id, @actor)
    assert [_] = Telephony.list_voicemails(scope)
  end

  test "greetings: audio only, by content; the temporary one wins", %{
    t: t,
    scope: scope,
    ext: ext,
    user: user
  } do
    assert {:error, :no_mailbox} = Telephony.put_greeting(scope, ext.id, "busy", @mp3, user)
    {:ok, _} = Telephony.save_mailbox(scope, ext.id, %{pin: "4831"}, user)
    assert {:error, :not_audio} = Telephony.put_greeting(scope, ext.id, "busy", "<html>", user)
    assert :ok = Telephony.put_greeting(scope, ext.id, "busy", @mp3, user)
    wav = "RIFF" <> <<0, 0, 0, 0>> <> "WAVEfmt " <> :binary.copy(<<0>>, 50)
    assert :ok = Telephony.put_greeting(scope, ext.id, "unavailable", wav, user)
    mb = Voicemail.mailbox_system(t.id, ext.id)
    assert %{kind: "busy", format: "mp3"} = Voicemail.greeting_system(mb, :busy)
    assert %{kind: "unavailable", format: "wav"} = Voicemail.greeting_system(mb, :unavailable)
    assert :ok = Telephony.put_greeting(scope, ext.id, "temporary", @mp3, user)
    assert %{kind: "temporary"} = Voicemail.greeting_system(mb, :busy)
    :ok = Telephony.delete_greeting(scope, ext.id, "temporary", user)
    assert Enum.sort(Telephony.greetings(scope, ext.id)) == ["busy", "unavailable"]
  end

  defp discard(:discard), do: {:discard, nil}
  defp discard(other), do: other
end
