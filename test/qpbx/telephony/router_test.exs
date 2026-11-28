defmodule QPBX.Telephony.RouterTest do
  use ExUnit.Case, async: true
  alias QPBX.Core.{NumberRule, OutboundRoute}
  alias QPBX.Telephony.Router

  @domain "acme.pbx.test"

  defp ext(number, opts \\ []) do
    devices = Keyword.get(opts, :devices, ["#{number}-desk"])

    Map.merge(
      %{
        id: "ext-#{number}",
        number: number,
        name: "Ext #{number}",
        external_caller_id: nil,
        dnd: false,
        call_waiting: true,
        forward_always: nil,
        forward_busy: nil,
        forward_no_answer: nil,
        no_answer_seconds: 20,
        follow_me_enabled: false,
        follow_me_numbers: [],
        devices: for(u <- devices, do: %{sip_credential: %{username: u}})
      },
      Map.new(Keyword.drop(opts, [:devices]))
    )
  end

  defp trunk(id, edge, opts \\ []) do
    Map.merge(
      %{
        id: id,
        edge_id: edge,
        enabled: true,
        caller_id_mode: "tenant_numbers",
        default_caller_id: nil,
        tenant_id: nil
      },
      Map.new(opts)
    )
  end

  defp route(trunk_ids, opts \\ []) do
    struct(
      OutboundRoute,
      Keyword.merge(
        [
          name: "r",
          prefixes: [],
          position: 0,
          enabled: true,
          strip_digits: 0,
          add_prefix: "",
          trunk_ids: trunk_ids
        ],
        opts
      )
    )
  end

  defp did(number, opts \\ []) do
    Map.merge(
      %{
        id: "did-#{number}",
        number: number,
        tenant_id: "t1",
        alias_of_id: nil,
        destination_type: nil,
        destination_id: nil,
        destination_number: nil
      },
      Map.new(opts)
    )
  end

  defp ctx(opts \\ []) do
    exts = Keyword.get(opts, :extensions, [ext("101"), ext("102")])

    dids =
      Keyword.get(opts, :dids, [
        did("+97221234567", destination_type: "extension", destination_id: "ext-102")
      ])

    %{
      tenant: %{
        tenant: %{id: "t1", sip_domain: @domain},
        rule: NumberRule.israel_default(),
        extensions: exts,
        routes: Keyword.get(opts, :routes, [route(["partner", "cellcom"], prefixes: ["+972"])]),
        dids: dids
      },
      platform: %{
        trunks:
          Map.new(
            Keyword.get(opts, :trunks, [trunk("partner", 1), trunk("cellcom", 2)]),
            &{&1.id, &1}
          ),
        emergency: [%{number: "100", trunk_id: "partner"}],
        classes: [],
        default_rule: NumberRule.israel_default()
      },
      dids: Map.new(dids, &{&1.number, &1}),
      in_use: Keyword.get(opts, :in_use, MapSet.new())
    }
  end

  defp from_phone(dest, ctx \\ ctx()),
    do: Router.plan(%{source: :device, auth_user: "101-desk", destination: dest}, ctx)

  # Follows the tree: the action after the given outcomes.
  defp walk(action, []), do: action
  defp walk(action, [o | rest]), do: walk(Map.fetch!(action, o), rest)

  describe "phone to extension" do
    test "all devices of the extension ring together, through Kamailio, with the caller's extension" do
      ctx = ctx(extensions: [ext("101"), ext("102", devices: ["102-desk", "102-mobile"])])
      a = from_phone("102", ctx)
      assert %{op: :dial, timeout: 20, ext_id: "ext-102"} = a
      assert a.dial =~ "{origination_caller_id_name=Ext 101,origination_caller_id_number=101}"

      assert a.dial =~
               "[qpbx_callee=102,sip_route_uri=sip:127.0.0.1:5060]sofia/qpbx/102-desk@#{@domain},"

      assert a.dial =~
               "[qpbx_callee=102,sip_route_uri=sip:127.0.0.1:5060]sofia/qpbx/102-mobile@#{@domain}"

      # Unanswered or busy: the mailbox takes a message (the call ends if there is none).
      assert %{
               op: :voicemail,
               ext_id: "ext-102",
               ext_number: "102",
               reason: :busy,
               otherwise: %{cause: "USER_BUSY"}
             } =
               walk(a, [:busy])

      assert %{op: :voicemail, reason: :unavailable, otherwise: %{cause: "NO_ANSWER"}} =
               walk(a, [:no_answer])
    end

    test "an unknown device is refused; an extension without devices is unanswered" do
      assert %{op: :reject, cause: "CALL_REJECTED"} =
               Router.plan(%{source: :device, auth_user: "999-x", destination: "102"}, ctx())

      ctx = ctx(extensions: [ext("101"), ext("102", devices: [])])
      assert %{op: :voicemail, reason: :unavailable} = from_phone("102", ctx)
    end
  end

  test "*97 is the caller's own mailbox" do
    assert %{op: :voicemail_menu} = from_phone("*97", ctx(extensions: [ext("101")]))
  end

  describe "extension features" do
    test "do not disturb is busy, or forward-on-busy" do
      assert %{op: :voicemail, reason: :busy} =
               from_phone("102", ctx(extensions: [ext("101"), ext("102", dnd: true)]))

      a =
        from_phone(
          "102",
          ctx(extensions: [ext("101"), ext("102", dnd: true, forward_busy: "103"), ext("103")])
        )

      assert a.dial =~ "103-desk@"
    end

    test "call waiting off: an extension on a call is busy" do
      ctx =
        ctx(
          extensions: [ext("101"), ext("102", call_waiting: false)],
          in_use: MapSet.new(["ext-102"])
        )

      assert %{op: :voicemail, reason: :busy} = from_phone("102", ctx)
      # With call waiting on (the default) it rings.
      assert %{op: :dial} = from_phone("102", %{ctx | in_use: MapSet.new()})
    end

    test "forward always, to an extension or an outside number (shown with the tenant's number)" do
      a =
        from_phone(
          "102",
          ctx(extensions: [ext("101"), ext("102", forward_always: "103"), ext("103")])
        )

      assert a.dial =~ "103-desk@" and not (a.dial =~ "102-desk")

      a =
        from_phone(
          "102",
          ctx(extensions: [ext("101"), ext("102", forward_always: "+972501234567")])
        )

      assert a.dial =~ "sip_h_X-QPBX-Trunk-Edge=1"
      assert a.dial =~ "origination_caller_id_number=+97221234567"
      assert a.dial =~ "sofia/qpbx/+972501234567@127.0.0.1:5060"
    end

    test "busy and no-answer forwarding" do
      ctx =
        ctx(
          extensions: [
            ext("101"),
            ext("102", forward_busy: "103", forward_no_answer: "104", no_answer_seconds: 15),
            ext("103"),
            ext("104")
          ]
        )

      a = from_phone("102", ctx)
      assert a.timeout == 15
      assert walk(a, [:busy]).dial =~ "103-desk@"
      assert walk(a, [:no_answer]).dial =~ "104-desk@"
      assert walk(a, [:failed]).dial =~ "104-desk@"
    end

    test "follow-me rings its numbers after the devices, then forward-on-no-answer" do
      e =
        ext("102",
          follow_me_enabled: true,
          follow_me_numbers: ["103", "+972501234567"],
          forward_no_answer: "104"
        )

      a = from_phone("102", ctx(extensions: [ext("101"), e, ext("103"), ext("104")]))
      fm = walk(a, [:no_answer])
      assert fm.dial =~ "103-desk@" and fm.dial =~ "sofia/qpbx/+972501234567@127.0.0.1:5060"
      assert walk(fm, [:no_answer]).dial =~ "104-desk@"
    end

    test "forwarding loops stop" do
      ctx =
        ctx(
          extensions: [
            ext("101"),
            ext("102", forward_always: "103"),
            ext("103", forward_always: "102")
          ]
        )

      assert %{op: :reject} = from_phone("102", ctx)
    end
  end

  describe "phone to an outside number" do
    test "local dialling to E.164; trunks in failover order; busy and no answer are final" do
      ctx = ctx(extensions: [ext("101", external_caller_id: "+97239999999"), ext("102")])
      a = from_phone("02-765-4321", ctx)

      assert a.dial =~ "sip_h_X-QPBX-Trunk-Edge=1" and
               a.dial =~ "sofia/qpbx/+97227654321@127.0.0.1:5060"

      assert a.dial =~ "origination_caller_id_number=+97239999999"
      assert walk(a, [:failed]).dial =~ "sip_h_X-QPBX-Trunk-Edge=2"
      assert walk(a, [:failed, :failed]) == %{op: :reject, cause: "NORMAL_TEMPORARY_FAILURE"}
      assert walk(a, [:busy]) == %{op: :reject, cause: "USER_BUSY"}
      assert walk(a, [:no_answer]) == %{op: :reject, cause: "NO_ANSWER"}
    end

    test "a trunk that must show its own number; disabled trunks skipped; the number rewritten for the carrier" do
      ctx =
        ctx(
          trunks: [
            trunk("partner", 1, enabled: false),
            trunk("cellcom", 2, caller_id_mode: "own_number", default_caller_id: "+97231111111")
          ],
          routes: [
            route(["partner", "cellcom"], prefixes: ["+972"], strip_digits: 3, add_prefix: "0")
          ]
        )

      a = from_phone("0501234567", ctx)

      assert a.dial =~ "sip_h_X-QPBX-Trunk-Edge=2" and
               a.dial =~ "origination_caller_id_number=+97231111111"

      assert a.dial =~ "sofia/qpbx/0501234567@127.0.0.1:5060"
      assert walk(a, [:failed]).op == :reject
    end

    test "no route, or a number that is not one" do
      assert %{op: :reject, cause: "NO_ROUTE_DESTINATION"} = from_phone("0044207946000", ctx())
      assert %{op: :reject, cause: "UNALLOCATED_NUMBER"} = from_phone("*99", ctx())
    end

    test "emergency numbers always use their trunk" do
      a = from_phone("100", ctx(routes: []))
      assert a.dial =~ "sip_h_X-QPBX-Trunk-Edge=1" and a.dial =~ "sofia/qpbx/100@127.0.0.1:5060"
    end

    test "the tenant's own number stays inside" do
      a = from_phone("02-123-4567", ctx())
      assert a.dial =~ "102-desk@"
    end
  end

  describe "carrier to a number" do
    defp from_carrier(dest, ctx, trunk_id \\ "partner", caller \\ "0501234567") do
      case Router.plan(
             %{source: :trunk, trunk_id: trunk_id, destination: dest, caller: caller},
             ctx
           ) do
        {:tenant_needed, "t1", did, caller} -> Router.plan_did(did, caller, ctx)
        other -> other
      end
    end

    test "the number in any form reaches its extension; the caller shown nationally" do
      for dest <- ["+97221234567", "97221234567", "021234567"] do
        a = from_carrier(dest, ctx())
        assert a.dial =~ "102-desk@", dest
        assert a.dial =~ "origination_caller_id_number=0501234567"
      end
    end

    test "a backup number routes like its main number" do
      dids = [
        did("+97221234567", destination_type: "extension", destination_id: "ext-102"),
        did("+97231234567", alias_of_id: "did-+97221234567")
      ]

      assert from_carrier("+97231234567", ctx(dids: dids)).dial =~ "102-desk@"
    end

    test "an external destination goes out showing the called number" do
      dids = [
        did("+97221234567", destination_type: "external", destination_number: "+972507777777")
      ]

      a = from_carrier("+97221234567", ctx(dids: dids))

      assert a.dial =~ "sofia/qpbx/+972507777777@127.0.0.1:5060" and
               a.dial =~ "origination_caller_id_number=+97221234567"
    end

    test "a number straight to an extension's voicemail, or hung up" do
      # As the cache holds them: %Did{} structs, not plain maps.
      vm = [
        struct(
          QPBX.Core.Did,
          Map.new(did("+97221234567", destination_type: "voicemail", destination_id: "ext-102"))
        )
      ]

      assert %{op: :voicemail, ext_id: "ext-102", reason: :unavailable} =
               from_carrier("+97221234567", ctx(dids: vm))

      off = [did("+97221234567", destination_type: "hangup")]

      assert %{op: :reject, cause: "NORMAL_CLEARING"} =
               from_carrier("+97221234567", ctx(dids: off))

      gone = [did("+97221234567", destination_type: "voicemail", destination_id: "ext-gone")]

      assert %{op: :reject, cause: "UNALLOCATED_NUMBER"} =
               from_carrier("+97221234567", ctx(dids: gone))
    end

    test "unknown numbers, unassigned numbers, and another tenant's number on a tenant's own trunk are refused" do
      assert %{op: :reject, cause: "UNALLOCATED_NUMBER"} = from_carrier("+97299999999", ctx())
      assert %{op: :reject} = from_carrier("+97221234567", ctx(dids: [did("+97221234567")]))
      ctx = ctx(trunks: [trunk("byoc", 9, tenant_id: "t2")])

      assert %{op: :reject, cause: "UNALLOCATED_NUMBER"} =
               from_carrier("+97221234567", ctx, "byoc")

      assert %{op: :reject} = from_carrier("+97221234567", ctx(), "nope")
    end
  end

  describe "echo test, transfers and redirects" do
    test "*43 is the loopback echo service" do
      a = from_phone("*43", ctx())
      assert %{op: :dial, dial: "loopback/qpbx-echo/public/XML"} = a
      assert walk(a, [:failed]).op == :reject
    end

    test "a transfer from a phone's call routes like dialling, with the same caller" do
      call = %{source: :device, auth_user: "101-desk", destination: "102"}
      assert Router.transfer(call, "*43", ctx()).dial =~ "loopback/qpbx-echo"
      a = Router.transfer(call, "102", ctx())
      assert a.dial =~ "102-desk@" and a.dial =~ "origination_caller_id_number=101"
    end

    test "a transferred carrier call stays in the number's tenant, caller shown nationally" do
      call = %{
        source: :trunk,
        trunk_id: "partner",
        destination: "+97221234567",
        caller: "+972501234567"
      }

      a = Router.transfer(call, "101", ctx())
      assert a.dial =~ "101-desk@" and a.dial =~ "origination_caller_id_number=0501234567"
      assert %{op: :reject} = Router.transfer(call, "101", %{ctx() | tenant: nil})
    end
  end

  test "dial strings cannot be broken by names" do
    ctx = ctx(extensions: [ext("101", name: "Evil,}[x]{"), ext("102")])
    a = from_phone("102", ctx)
    assert a.dial =~ "origination_caller_id_name=Evilx,"
  end
end
