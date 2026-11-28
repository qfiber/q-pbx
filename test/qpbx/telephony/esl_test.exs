defmodule QPBX.Telephony.ESLTest do
  use QPBX.DataCase, async: false
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Telephony.{Cache, Call}
  alias QPBX.Telephony.ESL.{Connection, Frame}

  @actor {:system, "test"}

  describe "frames" do
    test "headers, bodies split across reads, several frames at once" do
      event = Jason.encode!(%{"Event-Name" => "CHANNEL_PARK", "Unique-ID" => "u1"})

      data =
        "Content-Type: auth/request\n\nContent-Length: #{byte_size(event)}\nContent-Type: text/event-json\n\n#{event}"

      {part, rest} = String.split_at(data, 40)
      assert {[%{headers: %{"Content-Type" => "auth/request"}}], buffer} = Frame.parse(part)
      assert {[%{body: %{"Unique-ID" => "u1"}}], ""} = Frame.parse(buffer <> rest)

      assert {[%{body: "+OK 1"}], ""} =
               Frame.parse("Content-Type: api/response\nContent-Length: 5\n\n+OK 1")
    end
  end

  test "call outcomes" do
    assert Call.outcome(%{"variable_originate_disposition" => "SUCCESS"}) == :answered
    assert Call.outcome(%{"variable_originate_disposition" => "USER_BUSY"}) == :busy
    assert Call.outcome(%{"variable_originate_disposition" => "NO_ANSWER"}) == :no_answer

    assert Call.outcome(%{"variable_originate_disposition" => "USER_NOT_REGISTERED"}) ==
             :no_answer

    assert Call.outcome(%{"variable_originate_disposition" => "ORIGINATOR_CANCEL"}) == :cancelled

    assert Call.outcome(%{"variable_originate_disposition" => "NORMAL_TEMPORARY_FAILURE"}) ==
             :failed
  end

  describe "against a fake FreeSWITCH" do
    setup do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      old = Application.get_env(:qpbx, QPBX.Telephony)
      Application.put_env(:qpbx, QPBX.Telephony, esl_port: port, esl_password: "secret-pass")

      on_exit(fn ->
        Application.put_env(:qpbx, QPBX.Telephony, old || [])
        # Calls the fake FreeSWITCH never hangs up.
        for {_, pid, _, _} <- DynamicSupervisor.which_children(QPBX.Telephony.CallSupervisor),
            do: DynamicSupervisor.terminate_child(QPBX.Telephony.CallSupervisor, pid)
      end)

      Cache.clear()

      start_supervised!(Connection)
      {:ok, fs} = :gen_tcp.accept(listen, 5_000)
      send_frame(fs, "Content-Type: auth/request\n\n")
      assert recv_command(fs) == "auth secret-pass"
      send_frame(fs, "Content-Type: command/reply\nReply-Text: +OK accepted\n\n")
      assert "event json CHANNEL_PARK" <> _ = recv_command(fs)

      send_frame(
        fs,
        "Content-Type: command/reply\nReply-Text: +OK event listener enabled json\n\n"
      )

      wait_until(&Connection.connected?/0)

      tenant = tenant_fixture()
      scope = Core.scope_for(user_fixture(tenant))
      {:ok, e101} = Core.create_extension(scope, %{number: "101", name: "Reception"}, @actor)

      {:ok, e102} =
        Core.create_extension(scope, %{number: "102", name: "Sales", forward_busy: "101"}, @actor)

      {:ok, _, _} = Core.add_device(scope, e101, %{label: "desk", kind: "desk_phone"}, @actor)
      {:ok, _, _} = Core.add_device(scope, e102, %{label: "desk", kind: "desk_phone"}, @actor)
      %{fs: fs, tenant: tenant}
    end

    test "a parked call from a phone is bridged; busy follows the forward-on-busy; answered ends it",
         %{fs: fs, tenant: t} do
      QPBX.Events.subscribe(QPBX.Events.CallState)

      park(fs, "call-1", %{
        "variable_sip_h_X-QPBX-Source" => "device",
        "variable_sip_h_X-QPBX-Tenant" => t.id,
        "variable_sip_h_X-QPBX-Auth-User" => "101-desk",
        "Caller-Destination-Number" => "102",
        "Caller-Caller-ID-Number" => "101-desk"
      })

      assert %{app: "set", arg: "call_timeout=20"} = recv_sendmsg(fs, "call-1")
      assert %{app: "bridge", arg: dial, event_uuid: id} = recv_sendmsg(fs, "call-1")
      assert dial =~ "sofia/qpbx/102-desk@#{t.sip_domain}"

      # Busy: forwarded to 101.
      complete(fs, "call-1", id, "USER_BUSY")
      assert %{app: "set"} = recv_sendmsg(fs, "call-1")
      assert %{app: "bridge", arg: dial, event_uuid: id2} = recv_sendmsg(fs, "call-1")
      assert dial =~ "sofia/qpbx/101-desk@"

      # Connected (CHANNEL_BRIDGE): 101 is on a call from now on, not only after it ends.
      event(fs, %{"Event-Name" => "CHANNEL_BRIDGE", "Unique-ID" => "call-1"})

      e101 =
        Enum.find(
          Core.list_extensions(
            Core.scope_for(hd(Core.list_users(%Core.Scope{kind: :platform}, t)))
          ),
          &(&1.number == "101")
        )

      wait_until(fn -> MapSet.member?(QPBX.Telephony.Calls.in_use(), e101.id) end)

      complete(fs, "call-1", id2, "SUCCESS")
      assert %{command: "hangup", cause: "NORMAL_CLEARING"} = recv_sendmsg(fs, "call-1")
      event(fs, %{"Event-Name" => "CHANNEL_HANGUP_COMPLETE", "Unique-ID" => "call-1"})
      wait_until(fn -> Registry.lookup(QPBX.Telephony.Registry, "call-1") == [] end)

      # Busy lamps: 101 (calling) early, 102 rang then went off (busy), 101's device rang
      # (forward on busy: 101 itself), connected, then everything off.
      states = collect_states()
      assert {"101", "initiator", "early"} in states
      assert {"102", "recipient", "early"} in states

      # The lamp names the caller by extension, not by its device login.
      assert "101" in Process.get(:peers_of_102)

      assert {"102", "recipient", "terminated"} in states
      assert {"101", "recipient", "confirmed"} in states
      assert states |> List.last() |> elem(2) == "terminated"
    end

    test "call events in order: started, ringing, answered, ended; an unanswered call is missed",
         %{fs: fs, tenant: t} do
      QPBX.Events.subscribe(QPBX.Events.CallEvent)

      e102 =
        Enum.find(
          Core.list_extensions(
            Core.scope_for(hd(Core.list_users(%Core.Scope{kind: :platform}, t)))
          ),
          &(&1.number == "102")
        )

      park(fs, "call-ev", %{
        "variable_sip_h_X-QPBX-Source" => "device",
        "variable_sip_h_X-QPBX-Tenant" => t.id,
        "variable_sip_h_X-QPBX-Auth-User" => "101-desk",
        "Caller-Destination-Number" => "102",
        "Caller-Caller-ID-Number" => "101-desk"
      })

      assert %{app: "set"} = recv_sendmsg(fs, "call-ev")
      assert %{app: "bridge", event_uuid: id} = recv_sendmsg(fs, "call-ev")
      event(fs, %{"Event-Name" => "CHANNEL_PROGRESS", "Unique-ID" => "call-ev"})
      # A second ringing signal (early media) is the same ringing.
      event(fs, %{"Event-Name" => "CHANNEL_PROGRESS_MEDIA", "Unique-ID" => "call-ev"})
      event(fs, %{"Event-Name" => "CHANNEL_BRIDGE", "Unique-ID" => "call-ev"})
      complete(fs, "call-ev", id, "SUCCESS")
      assert %{command: "hangup"} = recv_sendmsg(fs, "call-ev")

      event(fs, %{
        "Event-Name" => "CHANNEL_HANGUP_COMPLETE",
        "Unique-ID" => "call-ev",
        "Hangup-Cause" => "NORMAL_CLEARING",
        "variable_duration" => "12",
        "variable_billsec" => "9"
      })

      events = collect_calls()
      assert Enum.map(events, & &1.type) == ~w(started ringing answered ended)

      assert Enum.all?(
               events,
               &(&1.call_id == "call-ev" and &1.tenant_id == t.id and &1.direction == "internal")
             )

      [started, ringing, answered, ended] = events
      assert started.from == "101" and started.to == "102" and started.extension_id
      assert ringing.target == %{type: "extension", extension_id: e102.id, number: "102"}
      assert answered.target.extension_id == e102.id

      assert %{disposition: "answered", cause: "NORMAL_CLEARING", duration: 12, billsec: 9} =
               ended

      # 102 does not answer and has no mailbox: the call ends, and 102 missed it.
      park(fs, "call-miss", %{
        "variable_sip_h_X-QPBX-Source" => "device",
        "variable_sip_h_X-QPBX-Tenant" => t.id,
        "variable_sip_h_X-QPBX-Auth-User" => "101-desk",
        "Caller-Destination-Number" => "102"
      })

      assert %{app: "set"} = recv_sendmsg(fs, "call-miss")
      assert %{app: "bridge", event_uuid: id} = recv_sendmsg(fs, "call-miss")
      event(fs, %{"Event-Name" => "CHANNEL_PROGRESS", "Unique-ID" => "call-miss"})
      complete(fs, "call-miss", id, "NO_ANSWER")
      assert %{command: "hangup", cause: "NO_ANSWER"} = recv_sendmsg(fs, "call-miss")

      event(fs, %{
        "Event-Name" => "CHANNEL_HANGUP_COMPLETE",
        "Unique-ID" => "call-miss",
        "Hangup-Cause" => "NO_ANSWER"
      })

      events = collect_calls()
      assert Enum.map(events, & &1.type) == ~w(started ringing ended missed)
      assert %{disposition: "no_answer", extension_ids: [id102]} = List.last(events)
      assert id102 == e102.id
    end

    test "click-to-call: rings the extension, then calls the target from it; live calls; hang up and transfer",
         %{fs: fs, tenant: t} do
      scope = Core.scope_for(hd(Core.list_users(%Core.Scope{kind: :platform}, t)))
      e101 = Enum.find(Core.list_extensions(scope), &(&1.number == "101"))
      QPBX.Events.subscribe(QPBX.Events.CallEvent)

      task = Task.async(fn -> QPBX.Telephony.originate(scope, e101.id, "102", @actor) end)
      cmd = recv_command(fs, Process.delete(:fs_rest) || "")
      send_frame(fs, "Content-Type: command/reply\nReply-Text: +OK Job-UUID: j1\n\n")
      assert {:ok, call_id} = Task.await(task)

      # The extension's device rings first, showing the target; the leg carries our tags.
      assert "bgapi originate {" <> _ = cmd
      assert cmd =~ "origination_uuid=#{call_id}"

      assert cmd =~ "qpbx_tenant=#{t.id}" and cmd =~ "qpbx_auth_user=101-desk" and
               cmd =~ "qpbx_destination=102"

      assert cmd =~ "origination_caller_id_number=102"
      assert cmd =~ "sofia/qpbx/101-desk@#{t.sip_domain}" and String.ends_with?(cmd, "&park()")

      # 101 answered: the parked leg is a call from 101 to 102, like 101 dialling it.
      event(fs, %{
        "Event-Name" => "CHANNEL_PARK",
        "Unique-ID" => call_id,
        "variable_qpbx_call" => "true",
        "variable_qpbx_source" => "device",
        "variable_qpbx_tenant" => t.id,
        "variable_qpbx_auth_user" => "101-desk",
        "variable_qpbx_destination" => "102",
        "Caller-Caller-ID-Number" => "102",
        "Caller-Destination-Number" => "101-desk"
      })

      assert %{app: "set"} = recv_sendmsg(fs, call_id)
      assert %{app: "bridge", arg: dial} = recv_sendmsg(fs, call_id)
      assert dial =~ "sofia/qpbx/102-desk@"

      assert_receive {:event,
                      %QPBX.Events.CallEvent{
                        type: "started",
                        call_id: ^call_id,
                        from: "101",
                        to: "102",
                        direction: "internal"
                      }}

      assert [%{call_id: ^call_id, from: "101", to: "102", answered: false}] =
               QPBX.Telephony.list_live_calls(scope)

      # Another tenant can neither see nor touch it.
      other = Core.scope_for(user_fixture(tenant_fixture()))
      assert QPBX.Telephony.list_live_calls(other) == []
      assert {:error, :not_found} = QPBX.Telephony.hangup_call(other, call_id, @actor)
      assert {:error, :not_found} = QPBX.Telephony.transfer_call(other, call_id, "102", @actor)

      assert {:error, :bad_target} =
               QPBX.Telephony.transfer_call(scope, call_id, "102 & reload", @actor)

      task = Task.async(fn -> QPBX.Telephony.transfer_call(scope, call_id, "*43", @actor) end)

      assert recv_command(fs, Process.delete(:fs_rest) || "") ==
               "api uuid_transfer #{call_id} *43 XML public"

      send_frame(fs, "Content-Type: api/response\nContent-Length: 3\n\n+OK")
      assert :ok = Task.await(task)

      # Ended at once (uuid_kill): a hangup message would wait behind the running bridge.
      task = Task.async(fn -> QPBX.Telephony.hangup_call(scope, call_id, @actor) end)

      assert recv_command(fs, Process.delete(:fs_rest) || "") ==
               "api uuid_kill #{call_id} NORMAL_CLEARING"

      send_frame(fs, "Content-Type: api/response\nContent-Length: 3\n\n+OK")
      assert :ok = Task.await(task)

      # Refused before anything rings.
      assert {:error, :bad_target} = QPBX.Telephony.originate(scope, e101.id, "abc", @actor)

      assert {:error, :not_found} =
               QPBX.Telephony.originate(scope, Ecto.UUID.generate(), "102", @actor)

      assert {:error, :not_found} = QPBX.Telephony.originate(other, e101.id, "102", @actor)
    end

    test "a transfer re-routes the parked channel instead of hanging up; a 302 is followed",
         %{fs: fs, tenant: t} do
      QPBX.Events.subscribe(QPBX.Events.CallEvent)

      park(fs, "call-5", %{
        "variable_sip_h_X-QPBX-Source" => "device",
        "variable_sip_h_X-QPBX-Tenant" => t.id,
        "variable_sip_h_X-QPBX-Auth-User" => "101-desk",
        "Caller-Destination-Number" => "102"
      })

      assert %{app: "set"} = recv_sendmsg(fs, "call-5")
      assert %{app: "bridge", event_uuid: id} = recv_sendmsg(fs, "call-5")

      # 102 transferred the caller (REFER): the bridge ends with a transfer in the history,
      # then FreeSWITCH parks the channel again with the new destination.
      event(fs, %{
        "Event-Name" => "CHANNEL_EXECUTE_COMPLETE",
        "Unique-ID" => "call-5",
        "Application-UUID" => id,
        "variable_originate_disposition" => "SUCCESS",
        "variable_transfer_history" => "1:uuid:bl_xfer:*43/public/XML"
      })

      event(fs, %{
        "Event-Name" => "CHANNEL_PARK",
        "Unique-ID" => "call-5",
        "variable_qpbx_call" => "true",
        "Caller-Destination-Number" => "*43"
      })

      assert %{app: "set"} = recv_sendmsg(fs, "call-5")

      assert %{app: "bridge", arg: "loopback/qpbx-echo/public/XML", event_uuid: id2} =
               recv_sendmsg(fs, "call-5")

      assert_receive {:event,
                      %QPBX.Events.CallEvent{type: "transferred", call_id: "call-5", to: "*43"}}

      # The echo answers 302 to 102: followed.
      event(fs, %{
        "Event-Name" => "CHANNEL_EXECUTE_COMPLETE",
        "Unique-ID" => "call-5",
        "Application-UUID" => id2,
        "variable_originate_disposition" => "REDIRECTION_TO_NEW_DESTINATION",
        "variable_sip_redirect_contact_user_0" => "102"
      })

      assert %{app: "set"} = recv_sendmsg(fs, "call-5")
      assert %{app: "bridge", arg: dial} = recv_sendmsg(fs, "call-5")
      assert dial =~ "102-desk@"
    end

    test "voicemail: an unanswered extension takes a message; *97 plays it behind the PIN",
         %{fs: fs, tenant: t} do
      user = user_fixture(t)
      scope = Core.scope_for(user)
      {:ok, e103} = Core.create_extension(scope, %{number: "103", name: "Away"}, @actor)
      {:ok, _, _} = Core.add_device(scope, e103, %{label: "desk", kind: "desk_phone"}, @actor)
      {:ok, _} = QPBX.Telephony.save_mailbox(scope, e103.id, %{pin: "4831"}, user)
      QPBX.Events.subscribe(QPBX.Events.VoicemailChanged)
      Cache.clear()

      from = fn auth, uuid, dest ->
        park(fs, uuid, %{
          "variable_sip_h_X-QPBX-Source" => "device",
          "variable_sip_h_X-QPBX-Tenant" => t.id,
          "variable_sip_h_X-QPBX-Auth-User" => auth,
          "Caller-Caller-ID-Number" => auth,
          "Caller-Destination-Number" => dest
        })
      end

      # 101 calls 103, nobody answers: greeting, tone, record.
      from.("101-desk", "vm-1", "103")
      assert %{app: "set"} = recv_sendmsg(fs, "vm-1")
      assert %{app: "bridge", event_uuid: bridge} = recv_sendmsg(fs, "vm-1")
      complete(fs, "vm-1", bridge, "NO_ANSWER")
      assert %{app: "answer"} = recv_sendmsg(fs, "vm-1")
      assert %{app: "sleep"} = recv_sendmsg(fs, "vm-1")
      assert %{app: "playback", arg: greeting} = recv_sendmsg(fs, "vm-1")

      assert greeting =~
               "vm-person.wav!digits/1.wav!digits/0.wav!digits/3.wav!voicemail/vm-not_available.wav"

      assert %{app: "playback", arg: "tone_stream://" <> _} = recv_sendmsg(fs, "vm-1")
      assert %{app: "set", arg: "playback_terminators=#"} = recv_sendmsg(fs, "vm-1")
      assert %{app: "record", arg: rec, event_uuid: rec_id} = recv_sendmsg(fs, "vm-1")
      [path, "180", "200", "5"] = String.split(rec)
      assert String.starts_with?(path, QPBX.Storage.temp_dir())

      # FreeSWITCH wrote the recording; the caller pressed # after 4 seconds.
      File.mkdir_p!(QPBX.Storage.temp_dir())
      File.write!(path, "ID3" <> :binary.copy(<<1>>, 300))

      event(fs, %{
        "Event-Name" => "CHANNEL_EXECUTE_COMPLETE",
        "Unique-ID" => "vm-1",
        "Application" => "record",
        "Application-UUID" => rec_id,
        "variable_record_seconds" => "4"
      })

      assert %{app: "playback", arg: "voicemail/vm-goodbye.wav"} = recv_sendmsg(fs, "vm-1")
      assert %{app: "hangup"} = recv_sendmsg(fs, "vm-1")
      event(fs, %{"Event-Name" => "CHANNEL_HANGUP_COMPLETE", "Unique-ID" => "vm-1"})
      eid = e103.id
      assert_receive {:event, %QPBX.Events.VoicemailChanged{extension_id: ^eid, new: 1}}, 2_000
      refute File.exists?(path), "the plain recording is removed once stored"
      [{v, ^eid}] = QPBX.Telephony.list_voicemails(scope)
      assert %{duration: 4, caller_number: "101", folder: "new"} = v

      # 103 dials *97: wrong PIN, then the right one; hears the message and deletes it (7).
      from.("103-desk", "vm-2", "*97")
      assert %{app: "answer"} = recv_sendmsg(fs, "vm-2")
      assert %{app: "sleep"} = recv_sendmsg(fs, "vm-2")
      assert %{app: "play_and_get_digits", event_uuid: p1, arg: arg} = recv_sendmsg(fs, "vm-2")
      assert arg =~ "qpbx_vm_pin1"

      digits = fn id, var, value, app ->
        event(fs, %{
          "Event-Name" => "CHANNEL_EXECUTE_COMPLETE",
          "Unique-ID" => "vm-2",
          "Application" => app,
          "Application-UUID" => id,
          ("variable_" <> var) => value
        })
      end

      digits.(p1, "qpbx_vm_pin1", "1111", "play_and_get_digits")
      assert %{app: "playback", arg: "voicemail/vm-fail_auth.wav"} = recv_sendmsg(fs, "vm-2")
      assert %{app: "play_and_get_digits", event_uuid: p2} = recv_sendmsg(fs, "vm-2")
      digits.(p2, "qpbx_vm_pin2", "4831", "play_and_get_digits")
      assert %{app: "playback", arg: "voicemail/vm-you_have.wav"} = recv_sendmsg(fs, "vm-2")
      assert %{app: "say", arg: "en number pronounced 1"} = recv_sendmsg(fs, "vm-2")
      assert %{app: "playback"} = recv_sendmsg(fs, "vm-2")
      assert %{app: "playback", arg: plain} = recv_sendmsg(fs, "vm-2")
      assert File.read!(plain) == "ID3" <> :binary.copy(<<1>>, 300)
      assert %{app: "play_and_get_digits", event_uuid: k0} = recv_sendmsg(fs, "vm-2")
      digits.(k0, "qpbx_vm_key0", "7", "play_and_get_digits")
      assert %{app: "playback", arg: "voicemail/vm-deleted.wav"} = recv_sendmsg(fs, "vm-2")

      assert %{app: "playback", arg: "voicemail/vm-no_more_messages.wav"} =
               recv_sendmsg(fs, "vm-2")

      refute File.exists?(plain), "the decrypted copy is removed after it played"

      assert_receive {:event,
                      %QPBX.Events.VoicemailChanged{extension_id: ^eid, new: 0, saved: 0}},
                     2_000

      assert QPBX.Telephony.list_voicemails(scope) == []
    end

    test "call admission: a barred class is hung up; an allowed call is cut off when its minutes run out",
         %{fs: fs} do
      plan = plan_fixture(%{allowed_destination_classes: ["local"], minutes_local_per_hour: 5})
      t = tenant_fixture(plan_id: plan.id)
      scope = Core.scope_for(user_fixture(t))
      {:ok, e} = Core.create_extension(scope, %{number: "101", name: "A"}, @actor)
      {:ok, _, _} = Core.add_device(scope, e, %{label: "desk", kind: "desk_phone"}, @actor)
      platform = Core.scope_for(platform_admin_fixture())

      {:ok, trunk} =
        Core.create_trunk(
          platform,
          %{name: "A", auth_mode: "ip", addresses: [%{host: "192.0.2.99"}]},
          @actor
        )

      {:ok, _} = Core.create_number_class(platform, %{prefix: "+9725", class: "mobile"}, @actor)

      {:ok, _} =
        Core.create_route(
          scope,
          %{name: "IL", prefixes: ["+972"], destination_class: "local", trunk_ids: [trunk.id]},
          @actor
        )

      Cache.clear()

      device = %{
        "variable_sip_h_X-QPBX-Source" => "device",
        "variable_sip_h_X-QPBX-Tenant" => t.id,
        "variable_sip_h_X-QPBX-Auth-User" => "101-desk"
      }

      park(fs, "call-6", Map.put(device, "Caller-Destination-Number", "0501234567"))
      assert %{command: "hangup", cause: "OUTGOING_CALL_BARRED"} = recv_sendmsg(fs, "call-6")

      park(fs, "call-7", Map.put(device, "Caller-Destination-Number", "02-765-4321"))
      assert %{app: "set"} = recv_sendmsg(fs, "call-7")
      assert %{app: "bridge", arg: dial, event_uuid: id} = recv_sendmsg(fs, "call-7")

      # Tagged for its CDR: tenant, caller extension, dialed number; outbound once a carrier is dialed.
      tags = Process.get(:cdr_tags)
      assert "export qpbx_tenant=#{t.id}" in tags and "export qpbx_caller=101" in tags

      assert "set qpbx_destination=02-765-4321" in tags or
               "set qpbx_destination=027654321" in tags

      assert "export qpbx_direction=internal" in tags and "set qpbx_direction=outbound" in tags
      assert dial =~ "qpbx_direction=outbound" and dial =~ "qpbx_trunk_id=#{trunk.id}"
      assert dial =~ "{execute_on_answer='sched_hangup +300 ALLOTTED_TIMEOUT'}"
      assert dial =~ "sofia/qpbx/+97227654321@127.0.0.1:5060"

      # Talk time is recorded when the carrier call ends.
      event(fs, %{"Event-Name" => "CHANNEL_BRIDGE", "Unique-ID" => "call-7"})
      Process.sleep(1_100)
      complete(fs, "call-7", id, "SUCCESS")
      assert %{command: "hangup"} = recv_sendmsg(fs, "call-7")
      assert %{"local" => %{hour: secs}} = QPBX.Telephony.Usage.used(t.id, t.timezone)
      assert secs >= 1
    end

    test "a call nobody can route is hung up with its cause; calls not parked by us are left alone",
         %{fs: fs, tenant: t} do
      park(fs, "other", %{"variable_qpbx_call" => "false"})

      park(fs, "call-2", %{
        "variable_sip_h_X-QPBX-Source" => "device",
        "variable_sip_h_X-QPBX-Tenant" => t.id,
        "variable_sip_h_X-QPBX-Auth-User" => "999-ghost",
        "Caller-Destination-Number" => "102"
      })

      assert %{command: "hangup", cause: "CALL_REJECTED"} = recv_sendmsg(fs, "call-2")
    end

    test "a carrier call to an unknown number is refused", %{fs: fs} do
      park(fs, "call-3", %{
        "variable_sip_h_X-QPBX-Source" => "trunk",
        "variable_sip_h_X-QPBX-Trunk" => Ecto.UUID.generate(),
        "Caller-Destination-Number" => "+97299999999"
      })

      assert %{command: "hangup", cause: "UNALLOCATED_NUMBER"} = recv_sendmsg(fs, "call-3")
    end
  end

  defp collect_states(acc \\ []) do
    receive do
      {:event, %QPBX.Events.CallState{extension: e, direction: d, state: st, peer: peer}} ->
        if e == "102", do: Process.put(:peers_of_102, [peer | Process.get(:peers_of_102, [])])
        collect_states([{e, d, st} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp collect_calls(acc \\ []) do
    receive do
      {:event, %QPBX.Events.CallEvent{} = e} -> collect_calls([e | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  ## Fake FreeSWITCH helpers

  defp send_frame(fs, data), do: :ok = :gen_tcp.send(fs, data)

  defp event(fs, map) do
    body = Jason.encode!(map)
    send_frame(fs, "Content-Length: #{byte_size(body)}\nContent-Type: text/event-json\n\n#{body}")
  end

  defp park(fs, uuid, vars),
    do:
      event(
        fs,
        Map.merge(
          %{"Event-Name" => "CHANNEL_PARK", "Unique-ID" => uuid, "variable_qpbx_call" => "true"},
          vars
        )
      )

  defp complete(fs, uuid, app_uuid, disposition) do
    event(fs, %{
      "Event-Name" => "CHANNEL_EXECUTE_COMPLETE",
      "Unique-ID" => uuid,
      "Application" => "bridge",
      "Application-UUID" => app_uuid,
      "variable_originate_disposition" => disposition
    })
  end

  # Reads one command (up to the blank line, plus a body if it has a content-length).
  defp recv_command(fs, buffer \\ "") do
    case :binary.split(buffer, "\n\n") do
      [head, rest] ->
        len =
          Regex.run(~r/content-length: (\d+)/i, head)
          |> then(&if(&1, do: String.to_integer(List.last(&1)), else: 0))

        rest = if byte_size(rest) < len, do: rest <> recv!(fs, len - byte_size(rest)), else: rest
        Process.put(:fs_rest, binary_part(rest, len, byte_size(rest) - len))
        if len > 0, do: {head, binary_part(rest, 0, len)}, else: head

      [_] ->
        recv_command(fs, buffer <> recv!(fs, 0))
    end
  end

  defp recv!(fs, n) do
    {:ok, data} = :gen_tcp.recv(fs, n, 5_000)
    data
  end

  defp recv_sendmsg(fs, uuid) do
    {head, body} =
      case recv_command(fs, Process.delete(:fs_rest) || "") do
        {head, body} -> {head, body}
        head -> {head, nil}
      end

    send_frame(fs, "Content-Type: command/reply\nReply-Text: +OK\n\n")
    assert head =~ "sendmsg " <> uuid

    h =
      for l <- String.split(head, "\n"),
          [k, v] <- [String.split(l, ": ", parts: 2)],
          into: %{},
          do: {String.downcase(k), v}

    msg = %{
      command: h["call-command"],
      app: h["execute-app-name"],
      arg: body,
      event_uuid: h["event-uuid"],
      cause: h["hangup-cause"]
    }

    # CDR tags (qpbx_* variables) are kept aside for tests that check them.
    if msg.app in ["set", "export"] and String.starts_with?(msg.arg || "", "qpbx_") do
      Process.put(:cdr_tags, [msg.app <> " " <> msg.arg | Process.get(:cdr_tags, [])])
      recv_sendmsg(fs, uuid)
    else
      msg
    end
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
