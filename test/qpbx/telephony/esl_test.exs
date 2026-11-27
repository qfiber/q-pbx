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

    %{
      command: h["call-command"],
      app: h["execute-app-name"],
      arg: body,
      event_uuid: h["event-uuid"],
      cause: h["hangup-cause"]
    }
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
