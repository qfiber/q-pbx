defmodule QPBX.Telephony.PromptsTest do
  use QPBX.DataCase, async: true
  import QPBX.Fixtures
  alias QPBX.{Core, Telephony}

  @wav <<"RIFF", 36::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
         8000::little-32, 16_000::little-32, 2::little-16, 16::little-16, "data", 0::little-32>>

  setup do
    t = tenant_fixture()
    admin = user_fixture(t, "tenant_admin")
    %{scope: Core.scope_for(admin), admin: admin}
  end

  test "upload, list, play back and delete; names unique per tenant; audio only", %{
    scope: scope,
    admin: admin
  } do
    assert {:ok, p} = Telephony.upload_prompt(scope, " Welcome ", @wav, admin)
    assert %{name: "Welcome", format: "wav"} = p
    assert [%{id: id}] = Telephony.list_prompts(scope)
    assert {:ok, @wav, "wav"} = Telephony.prompt_audio(scope, id)

    assert {:error, cs} = Telephony.upload_prompt(scope, "Welcome", @wav, admin)
    assert errors_on(cs)[:name]
    assert {:error, :not_audio} = Telephony.upload_prompt(scope, "Text", "hello", admin)

    assert {:error, :too_large} =
             Telephony.upload_prompt(scope, "Big", @wav <> :binary.copy("a", 5_000_000), admin)

    # Another tenant sees nothing of it.
    other = Core.scope_for(user_fixture(tenant_fixture(), "tenant_admin"))
    assert Telephony.list_prompts(other) == []
    assert {:error, :not_found} = Telephony.prompt_audio(other, id)
    assert {:error, :not_found} = Telephony.delete_prompt(other, id, admin)

    assert {:ok, _} = Telephony.delete_prompt(scope, id, admin)
    assert Telephony.list_prompts(scope) == []
  end

  test "the system prompts offered are a fixed list, and only those count as system prompts" do
    assert {"ivr/ivr-thank_you_for_calling.wav", _} = hd(Telephony.system_prompts())
    assert Telephony.system_prompt?("voicemail/vm-goodbye.wav")
    refute Telephony.system_prompt?("ivr/ivr-asterisk_like_syphilis.wav")
    refute Telephony.system_prompt?("../../etc/passwd")
  end
end
