defmodule QPBX.Telephony.AdmissionTest do
  use QPBX.DataCase, async: false
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Events.{FraudAlert, LimitReached}
  alias QPBX.Telephony.{Admission, Fraud, Usage}

  @actor {:system, "test"}

  setup do
    Fraud.reset()
    on_exit(&Fraud.reset/0)
    :ok
  end

  defp snapshot(plan_attrs, tz \\ "Asia/Jerusalem") do
    plan = plan_fixture(plan_attrs)
    t = tenant_fixture(plan_id: plan.id, timezone: tz)
    Core.telephony_tenant(t.id)
  end

  defp call(class, number \\ "+97221234567"), do: %{e164: number, class: class, emergency: false}

  # Admission joins slots in the calling process; a fresh process per call keeps tests independent.
  defp in_process(fun) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:result, fun.()})
        Process.sleep(:infinity)
      end)

    receive do
      {:result, r} -> {r, pid}
    end
  end

  describe "destination classes" do
    test "the plan's classes; an empty list allows all but premium (the high-cost list)" do
      QPBX.Events.subscribe(LimitReached)
      s = snapshot(%{allowed_destination_classes: ["local"]})
      assert {:ok, nil} = Admission.admit_outbound(s, call("local"), "101")

      assert {:reject, "OUTGOING_CALL_BARRED"} =
               Admission.admit_outbound(s, call("mobile"), "101")

      assert_receive {:event, %LimitReached{limit: "destination_class", detail: "mobile"}}

      s = snapshot(%{})
      assert {:ok, _} = Admission.admit_outbound(s, call("international", "+442079460000"), "101")
      assert {:reject, _} = Admission.admit_outbound(s, call("premium", "+972190000000"), "101")
      s = snapshot(%{allowed_destination_classes: ~w(local premium)})
      assert {:ok, _} = Admission.admit_outbound(s, call("premium"), "101")
    end
  end

  describe "concurrent calls" do
    test "total, inbound and per-extension caps when a call starts" do
      s =
        snapshot(%{
          max_concurrent_calls_total: 2,
          max_concurrent_calls_inbound: 1,
          max_concurrent_calls_per_extension: 1
        })

      {r1, p1} = in_process(fn -> Admission.admit_call(s, :inbound, nil) end)
      assert r1 == :ok
      {r2, _} = in_process(fn -> Admission.admit_call(s, :inbound, nil) end)
      assert r2 == {:reject, "NORMAL_CIRCUIT_CONGESTION"}
      {r3, _} = in_process(fn -> Admission.admit_call(s, :internal, "ext-1") end)
      assert r3 == :ok
      # Total reached (2): nothing more, from anywhere.
      {r4, _} = in_process(fn -> Admission.admit_call(s, :internal, "ext-2") end)
      assert r4 == {:reject, "NORMAL_CIRCUIT_CONGESTION"}
      # A call ending frees its slots.
      Process.exit(p1, :kill)
      Process.sleep(50)
      {r5, _} = in_process(fn -> Admission.admit_call(s, :internal, "ext-1") end)
      assert r5 == {:reject, "USER_BUSY"}, "extension 1 already has its one call"
    end

    test "outbound cap before a carrier call" do
      s = snapshot(%{max_concurrent_calls_outbound: 1})
      {r1, _} = in_process(fn -> Admission.admit_outbound(s, call("local"), "101") end)
      assert {:ok, _} = r1
      {r2, _} = in_process(fn -> Admission.admit_outbound(s, call("local"), "102") end)
      assert r2 == {:reject, "NORMAL_CIRCUIT_CONGESTION"}
    end
  end

  describe "minute caps" do
    test "per class and period, and the total; the call may last what the tightest cap has left" do
      s = snapshot(%{minutes_international_per_hour: 3, outbound_minutes_per_day: 10})
      tid = s.tenant.id
      Usage.add(tid, "international", 120, DateTime.utc_now())

      assert {:ok, 60} =
               Admission.admit_outbound(s, call("international", "+442079460000"), "101")

      Usage.add(tid, "international", 60, DateTime.utc_now())

      assert {:reject, "OUTGOING_CALL_BARRED"} =
               Admission.admit_outbound(s, call("international", "+442079460000"), "101")

      # Local is not capped per hour, but the daily total (10 min) counts every class: 7 left.
      assert {:ok, 420} = Admission.admit_outbound(s, call("local"), "101")
      Usage.add(tid, "local", 420, DateTime.utc_now())
      assert {:reject, _} = Admission.admit_outbound(s, call("local"), "101")
    end

    test "usage: hour, day and month in the tenant's time zone" do
      s = snapshot(%{}, "Asia/Jerusalem")
      tid = s.tenant.id
      now = ~U[2026-03-10 23:30:00Z]
      # 01:30 on the 11th in Jerusalem: the previous UTC hour (22:00Z, 00:00 local) is today.
      Usage.add(tid, "local", 60, ~U[2026-03-10 22:10:00Z])
      Usage.add(tid, "local", 30, ~U[2026-03-10 21:50:00Z])
      Usage.add(tid, "local", 10, now)

      assert %{"local" => %{hour: 10, day: 70, month: 100}} =
               Usage.used(tid, "Asia/Jerusalem", now)
    end
  end

  test "emergency calls pass every limit and are logged" do
    s =
      snapshot(%{
        allowed_destination_classes: ["local"],
        max_concurrent_calls_outbound: 0,
        outbound_minutes_per_day: 0
      })

    Fraud.update_settings(%{international_spike_calls: 1}, @actor)

    assert {:ok, nil} =
             Admission.admit_outbound(
               s,
               %{e164: "100", class: "emergency", emergency: true},
               "101"
             )

    assert Enum.any?(Core.list_audit_logs(), &(&1.action == "call.emergency"))
  end

  describe "velocity rules" do
    test "an international spike alerts once and blocks international and premium; local still works; lifted by an admin" do
      QPBX.Events.subscribe(FraudAlert)

      {:ok, _} =
        Fraud.update_settings(
          %{international_spike_calls: 3, quiet_start_hour: 0, quiet_end_hour: 0},
          @actor
        )

      s = snapshot(%{})

      for _ <- 1..3,
          do:
            assert(
              {:ok, _} =
                Admission.admit_outbound(s, call("international", "+442079460000"), "101")
            )

      assert {:reject, "OUTGOING_CALL_BARRED"} =
               Admission.admit_outbound(s, call("international", "+442079460000"), "101")

      assert_receive {:event, %FraudAlert{rule: "international_spike", blocked: true}}

      assert {:reject, _} =
               Admission.admit_outbound(s, call("international", "+442079460000"), "101")

      refute_receive {:event, %FraudAlert{}}, 50
      assert {:ok, _} = Admission.admit_outbound(s, call("local"), "101")

      [block] = Fraud.list_blocks()
      assert block.tenant_id == s.tenant.id
      :ok = Fraud.lift(block.id, @actor)
      refute Fraud.blocked?(s.tenant.id)
      # Lifting starts a fresh window: the next international call is not blocked again.
      assert {:ok, _} = Admission.admit_outbound(s, call("international", "+442079460000"), "101")
    end

    test "quiet hours: an alert, and a block only when the setting says so" do
      QPBX.Events.subscribe(FraudAlert)
      hour = DateTime.now!("Asia/Jerusalem").hour

      {:ok, _} =
        Fraud.update_settings(
          %{
            quiet_start_hour: hour,
            quiet_end_hour: rem(hour + 1, 24),
            block_in_quiet_hours: false
          },
          @actor
        )

      s = snapshot(%{})
      assert {:ok, _} = Admission.admit_outbound(s, call("international", "+442079460000"), "101")
      assert_receive {:event, %FraudAlert{rule: "quiet_hours", blocked: false}}

      {:ok, _} = Fraud.update_settings(%{block_in_quiet_hours: true}, @actor)
      s2 = snapshot(%{})

      assert {:reject, _} =
               Admission.admit_outbound(s2, call("international", "+442079460000"), "101")
    end

    test "quiet hours across midnight" do
      s = %{quiet_start_hour: 22, quiet_end_hour: 6}
      assert Fraud.quiet_hour?(~U[2026-01-01 21:30:00Z], "Etc/UTC", %{s | quiet_start_hour: 21})
      assert Fraud.quiet_hour?(~U[2026-01-01 03:00:00Z], "Etc/UTC", s)
      refute Fraud.quiet_hour?(~U[2026-01-01 12:00:00Z], "Etc/UTC", s)
    end
  end
end
