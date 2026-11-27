defmodule QPBX.Telephony.CdrsTest do
  use QPBX.DataCase, async: false
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Telephony.{Cache, CdrImporter, Cdrs}

  setup do
    dir = Path.join(System.tmp_dir!(), "qpbx-cdr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Cache.clear()
    t = tenant_fixture(timezone: "Asia/Jerusalem")
    %{dir: dir, t: t, scope: Core.scope_for(user_fixture(t))}
  end

  # A spooled leg as mod_json_cdr writes it (values URL-encoded).
  defp leg(vars),
    do: %{
      "core-uuid" => "x",
      "variables" => Map.new(vars, fn {k, v} -> {k, URI.encode_www_form(to_string(v))} end)
    }

  defp a_leg(t, uuid, extra \\ %{}) do
    leg(
      Map.merge(
        %{
          "uuid" => uuid,
          "call_uuid" => uuid,
          "direction" => "inbound",
          "channel_name" => "sofia/qpbx/101@x",
          "qpbx_tenant" => t.id,
          "qpbx_caller" => "101",
          "caller_id_name" => "Reception",
          "qpbx_destination" => "0501234567",
          "qpbx_direction" => "outbound",
          "start_epoch" => "1795800000",
          "answer_epoch" => "1795800004",
          "end_epoch" => "1795800064",
          "duration" => "64",
          "billsec" => "60",
          "hangup_cause" => "NORMAL_CLEARING"
        },
        extra
      )
    )
  end

  defp spool(dir, name, json, age \\ 10) do
    path = Path.join(dir, name)
    File.write!(path, if(is_binary(json), do: json, else: Jason.encode!(json)))
    File.touch!(path, System.os_time(:second) - age)
    path
  end

  test "a leg as a row: tenant, extension numbers, direction, times, disposition", %{t: t} do
    u = Ecto.UUID.generate()
    row = Cdrs.from_json(a_leg(t, u))

    assert %{
             tenant_id: tid,
             leg: "a",
             direction: "outbound",
             caller_number: "101",
             caller_name: "Reception",
             destination: "0501234567",
             duration: 64,
             billsec: 60,
             disposition: "answered"
           } = row

    assert tid == t.id and row.call_uuid == u
    assert row.answered_at == DateTime.from_unix!(1_795_800_004)

    b =
      Cdrs.from_json(
        a_leg(t, Ecto.UUID.generate(), %{
          "direction" => "outbound",
          # FreeSWITCH gives a b-leg its own call_uuid; the a-leg is its originating leg.
          "call_uuid" => Ecto.UUID.generate(),
          "originating_leg_uuid" => u,
          "qpbx_callee" => "+972501234567",
          "answer_epoch" => "0",
          "billsec" => "0",
          "hangup_cause" => "USER_BUSY",
          "qpbx_trunk_id" => t.id
        })
      )

    assert %{leg: "b", disposition: "busy", destination: "+972501234567", call_uuid: ^u} = b
    # Without our tags (FreeSWITCH alone): a carrier call is inbound.
    plain =
      Cdrs.from_json(
        leg(%{
          "uuid" => Ecto.UUID.generate(),
          "direction" => "inbound",
          "sip_h_X-QPBX-Source" => "trunk",
          "start_epoch" => "1795800000",
          "end_epoch" => "1795800001",
          "hangup_cause" => "NO_ANSWER"
        })
      )

    assert %{direction: "inbound", disposition: "no_answer", tenant_id: nil} = plain

    assert :skip =
             Cdrs.from_json(
               leg(%{"uuid" => Ecto.UUID.generate(), "channel_name" => "loopback/qpbx-echo-a"})
             )

    assert :skip = Cdrs.from_json(leg(%{"uuid" => "not-a-uuid"}))
  end

  test "the importer stores a batch, deletes the files, keeps young and broken ones; re-import is harmless",
       %{dir: dir, t: t, scope: scope} do
    u1 = Ecto.UUID.generate()
    p1 = spool(dir, "#{u1}.cdr.json", a_leg(t, u1))

    p2 =
      spool(
        dir,
        "b.cdr.json",
        a_leg(t, Ecto.UUID.generate(), %{"direction" => "outbound", "call_uuid" => u1})
      )

    young = spool(dir, "young.cdr.json", a_leg(t, Ecto.UUID.generate()), 0)
    bad = spool(dir, "bad.cdr.json", "{not json")
    gone = spool(dir, "gone.cdr.json", a_leg(%{id: Ecto.UUID.generate()}, Ecto.UUID.generate()))

    assert CdrImporter.run(dir) == 3
    refute File.exists?(p1) or File.exists?(p2) or File.exists?(gone)
    assert File.exists?(young)
    assert File.exists?(Path.join([dir, "bad", "bad.cdr.json"])) and not File.exists?(bad)

    # One row per call (a-legs) unless every leg is asked for.
    assert [%{leg_uuid: ^u1}] = Cdrs.search(scope, %{}, t.timezone)
    assert length(Cdrs.search(scope, %{"leg" => "all"}, t.timezone)) == 2
    # The leg of a tenant that does not exist is kept, without a tenant.
    assert QPBX.Repo.aggregate(from(c in QPBX.Telephony.Cdr, where: is_nil(c.tenant_id)), :count) ==
             1

    # The same leg again (a crash between insert and delete): not counted twice.
    spool(dir, "again.cdr.json", a_leg(t, u1))
    assert CdrImporter.run(dir) == 0

    assert [%{calls: 1, answered: 1, seconds: 60, direction: "outbound", day: ~D[2026-11-27]}] =
             Cdrs.usage_daily(scope, 100_000)
  end

  test "search: dates in the tenant's time zone, number, direction, disposition; other tenants never",
       %{t: t, scope: scope} do
    rows =
      for {vars, n} <- [
            {%{"start_epoch" => "1795800000", "qpbx_destination" => "0501112222"}, 1},
            {%{
               "start_epoch" => "1795880000",
               "qpbx_destination" => "0503334444",
               "qpbx_direction" => "inbound",
               "answer_epoch" => "0",
               "billsec" => "0",
               "hangup_cause" => "NO_ANSWER"
             }, 2}
          ] do
        _ = n
        Cdrs.from_json(a_leg(t, Ecto.UUID.generate(), vars))
      end

    Cdrs.insert_batch(rows, %{t.id => t.timezone})
    tz = t.timezone
    # 1795800000 = 2026-11-27 14:40 UTC; 1795880000 = 2026-11-28 12:53 UTC.
    assert [_] = Cdrs.search(scope, %{"from" => "2026-11-28", "to" => "2026-11-28"}, tz)
    assert [_, _] = Cdrs.search(scope, %{"from" => "2026-11-27"}, tz)
    assert [%{destination: "0501112222"}] = Cdrs.search(scope, %{"number" => "111"}, tz)
    assert [] = Cdrs.search(scope, %{"number" => "%"}, tz) -- Cdrs.search(scope, %{}, tz)
    assert [%{direction: "inbound"}] = Cdrs.search(scope, %{"direction" => "inbound"}, tz)
    assert [%{disposition: "no_answer"}] = Cdrs.search(scope, %{"disposition" => "no_answer"}, tz)
    other = Core.scope_for(user_fixture(tenant_fixture()))
    assert Cdrs.search(other, %{}, tz) == []
  end
end
