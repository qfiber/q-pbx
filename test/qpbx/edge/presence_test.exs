defmodule QPBX.Edge.PresenceTest do
  use ExUnit.Case, async: true
  alias QPBX.Edge.Presence
  alias QPBX.Events.CallState

  test "a call state becomes a pua_json dialog update for the extension" do
    e = %CallState{
      tenant_id: "t",
      domain: "acme.pbx.test",
      extension: "102",
      peer: "101",
      call_id: "c-102",
      state: "early",
      direction: "recipient",
      at: DateTime.utc_now()
    }

    assert %{
             "Event-Package" => "dialog",
             "From" => "sip:102@acme.pbx.test",
             "From-User" => "102",
             "To" => "sip:101@acme.pbx.test",
             "Call-ID" => "c-102",
             "State" => "early",
             "Direction" => "recipient",
             "Expires" => "3600"
           } = Presence.dialog(e)

    assert %{"State" => "terminated", "Expires" => "1", "To-User" => "102"} =
             Presence.dialog(%{e | state: "terminated", peer: nil})
  end

  test "voicemail light: no messages, or messages waiting" do
    assert %{
             "Event-Package" => "message-summary",
             "Messages-Waiting" => "no",
             "Message-Account" => "sip:101@acme.pbx.test"
           } =
             Presence.mwi("101", "acme.pbx.test")

    assert %{"Messages-Waiting" => "yes", "Messages-New" => "2"} =
             Presence.mwi("101", "acme.pbx.test", 2, 5)
  end
end
