defmodule QPBX.Notify.SourcesTest do
  use QPBX.DataCase, async: false
  import QPBX.Fixtures
  alias QPBX.{Core, Events, Notify}

  alias QPBX.Events.{
    CallEvent,
    EdgeAlert,
    EdgeBanned,
    ExtensionRegistration,
    FraudAlert,
    HealthChanged,
    LimitReached,
    LoginAlert
  }

  alias QPBX.Events.{
    TrunkStatusChanged,
    UsageSummary,
    UsageThresholdReached,
    VoicemailReceived,
    WebhookDeadLettered
  }

  alias QPBX.Edge.TrunkMonitor
  alias QPBX.Notify.Alerts.Alert
  alias QPBX.Notify.Sources
  alias QPBX.Telephony.{Usage, UsageAlerts}
  alias QPBX.Web.Health

  @actor {:system, "test"}
  @now DateTime.utc_now()

  setup do
    t = tenant_fixture()
    admin = user_fixture(t, "tenant_admin")
    %{t: t, admin: admin, padmin: platform_admin_fixture()}
  end

  # Runs an event's actions and returns the alerts it touched (by key).
  defp run(event) do
    for a <- Sources.actions(event) do
      case a do
        {:raise, attrs} -> {:ok, _} = Notify.raise_alert(attrs)
        {:resolve, tid, key} -> :ok = Notify.resolve_alert_key(tid, key)
      end
    end

    Repo.all(from a in Alert, order_by: [desc: a.updated_at])
  end

  defp alert(key),
    do: Repo.one(from a in Alert, where: a.key == ^key, order_by: [desc: a.inserted_at], limit: 1)

  describe "security" do
    test "failed SIP logins against a tenant's domain: that tenant's brute force; floods: a platform attack",
         %{t: t} do
      run(%EdgeBanned{
        ip: "203.0.113.9",
        port: 5060,
        reason: "auth failures",
        domain: t.sip_domain,
        at: @now
      })

      assert %{kind: "brute_force", category: "security", tenant_id: tid, severity: "warning"} =
               alert("sip_auth:203.0.113.9")

      assert tid == t.id

      run(%EdgeBanned{ip: "198.51.100.1", reason: "flood", at: @now})
      run(%EdgeBanned{ip: "198.51.100.2", reason: "scanner", at: @now})

      assert %{kind: "sip_attack", tenant_id: nil, severity: "critical", count: 2} =
               alert("sip_attack")
    end

    test "an office IP that would have been banned", %{} do
      run(%EdgeAlert{ip: "192.0.2.10", reason: "flood", at: @now})

      assert %{kind: "sip_attack", title: "Office IP 192.0.2.10 would have been banned"} =
               alert("office_ip:192.0.2.10")
    end

    test "fraud: a block is critical for the tenant; other rules are unusual activity", %{t: t} do
      run(%FraudAlert{
        tenant_id: t.id,
        rule: "international_spike",
        detail: "12 calls in 10 min",
        blocked: true,
        at: @now
      })

      assert %{kind: "fraud_block", severity: "critical"} = alert("fraud:international_spike")

      run(%FraudAlert{
        tenant_id: t.id,
        rule: "quiet_hours",
        detail: "a call at 03:00",
        blocked: false,
        at: @now
      })

      assert %{kind: "unusual_activity"} = alert("unusual:quiet_hours")
    end

    test "portal logins: new address and failed 2FA to the person (platform admins too); failures and blocks",
         %{t: t, admin: admin, padmin: padmin} do
      run(%LoginAlert{
        kind: "new_ip",
        account_type: "user",
        account_id: admin.id,
        tenant_id: t.id,
        ip: "203.0.113.50",
        at: @now
      })

      assert %{kind: "login_new_ip", state: "resolved"} =
               alert("login_ip:#{admin.id}:203.0.113.50")

      assert [%{alert: %{kind: "login_new_ip"}}] = Notify.list_notifications(admin)

      run(%LoginAlert{
        kind: "failed_2fa",
        account_type: "platform_admin",
        account_id: padmin.id,
        ip: "203.0.113.51",
        at: @now
      })

      assert [%{alert: %{kind: "failed_2fa"}}] = Notify.list_notifications(padmin)

      run(%LoginAlert{
        kind: "account_failures",
        account_type: "user",
        account_id: admin.id,
        tenant_id: t.id,
        detail: "5 failed logins",
        at: @now
      })

      assert %{kind: "brute_force", tenant_id: tid} = alert("portal_account:#{admin.id}")
      assert tid == t.id
      run(%LoginAlert{kind: "ip_blocked", ip: "203.0.113.52", detail: "1 h", at: @now})
      assert %{kind: "brute_force", tenant_id: nil} = alert("portal_ip:203.0.113.52")
    end

    test "Core reports a login from a new address and a wrong 2FA code", %{admin: admin} do
      Events.subscribe(LoginAlert)
      Core.create_session(admin, %{ip: "10.0.0.1"})
      refute_receive {:event, %LoginAlert{}}, 50
      Core.create_session(QPBX.Core.get_user(admin.id), %{ip: "10.0.0.1"})
      refute_receive {:event, %LoginAlert{}}, 50
      Core.create_session(QPBX.Core.get_user(admin.id), %{ip: "10.0.0.2"})
      assert_receive {:event, %LoginAlert{kind: "new_ip", ip: "10.0.0.2"}}

      Core.login_failed({10, 0, 0, 3}, admin, :totp)
      assert_receive {:event, %LoginAlert{kind: "failed_2fa", ip: "10.0.0.3"}}
      for _ <- 1..5, do: Core.login_failed({10, 0, 0, 4})
      assert_receive {:event, %LoginAlert{kind: "ip_blocked", ip: "10.0.0.4"}}
    end
  end

  describe "health" do
    test "a component down raises, back to ok resolves; trunk registrations are the trunk alerts' job",
         %{padmin: padmin} do
      run(%HealthChanged{
        component: "freeswitch",
        status: "error",
        detail: "event socket refused",
        at: @now
      })

      assert %{
               kind: "service_down",
               severity: "critical",
               state: "open",
               title: "FreeSWITCH is not answering"
             } = alert("health:freeswitch")

      assert [%{alert: %{kind: "service_down"}}] = Notify.list_notifications(padmin)
      run(%HealthChanged{component: "freeswitch", status: "ok", at: @now})
      assert %{state: "resolved"} = alert("health:freeswitch")

      for {c, kind} <- [
            {"disk", "disk"},
            {"certificate", "certificate_expiring"},
            {"backups", "backup_failed"},
            {"oban_backlog", "queue_backlog"}
          ] do
        run(%HealthChanged{component: c, status: "warning", detail: "x", at: @now})
        assert %{kind: ^kind, severity: "warning"} = alert("health:#{c}")
      end

      assert Sources.actions(%HealthChanged{
               component: "trunk_registrations",
               status: "error",
               at: @now
             }) == []
    end

    test "the health checker publishes a change only after it held two runs" do
      Events.subscribe(HealthChanged)
      s = %{told: %{}, pending: %{}}
      s = Health.changes(s, %{freeswitch: %{status: :ok, detail: "up"}})
      s = Health.changes(s, %{freeswitch: %{status: :error, detail: "down"}})
      refute_receive {:event, %HealthChanged{}}, 50
      s = Health.changes(s, %{freeswitch: %{status: :error, detail: "down"}})

      assert_receive {:event,
                      %HealthChanged{component: "freeswitch", status: "error", previous: "ok"}}

      s = Health.changes(s, %{freeswitch: %{status: :error, detail: "down"}})
      refute_receive {:event, %HealthChanged{}}, 50
      _ = Health.changes(s, %{freeswitch: %{status: :not_configured, detail: ""}})
      refute_receive {:event, %HealthChanged{}}, 50
    end

    test "a trunk down for two rounds raises; up again resolves; a shared trunk is the platform's",
         %{t: t} do
      Events.subscribe(TrunkStatusChanged)
      s = %{seen: %{}, told: %{}, streak: %{}, view: %{}}
      up = %{"tr1" => %{name: "Carrier", tenant_id: nil, up: true, reason: nil}}

      down = %{
        "tr1" => %{
          name: "Carrier",
          tenant_id: nil,
          up: false,
          reason: "no address answers OPTIONS"
        }
      }

      s = s |> TrunkMonitor.round_with(up) |> TrunkMonitor.round_with(up)
      refute_receive {:event, %TrunkStatusChanged{}}, 50
      s = TrunkMonitor.round_with(s, down)
      refute_receive {:event, %TrunkStatusChanged{}}, 50
      s = TrunkMonitor.round_with(s, down)
      assert_receive {:event, %TrunkStatusChanged{trunk_id: "tr1", up: false} = e}
      s = s |> TrunkMonitor.round_with(up) |> TrunkMonitor.round_with(up)
      assert_receive {:event, %TrunkStatusChanged{trunk_id: "tr1", up: true} = back}
      _ = s

      run(e)
      assert %{kind: "trunk_down", tenant_id: nil, state: "open"} = alert("trunk:tr1")
      run(back)
      assert %{state: "resolved"} = alert("trunk:tr1")

      run(%TrunkStatusChanged{
        trunk_id: "tr2",
        tenant_id: t.id,
        name: "Own",
        up: false,
        reason: "registration failed",
        at: @now
      })

      assert %{tenant_id: tid} = alert("trunk:tr2")
      assert tid == t.id
    end

    test "three crashes of one kind of process within 5 minutes: a crash loop" do
      start_supervised!(Sources)
      for _ <- 1..3, do: Sources.crashed("QPBX.Telephony.Call")
      :sys.get_state(Sources)
      assert %{kind: "crash_loop", severity: "critical"} = alert("crash:QPBX.Telephony.Call")
    end
  end

  describe "usage" do
    test "thresholds fire once each as minutes cross them, with what is left and the run-out", %{
      t: t
    } do
      plan = plan_fixture(%{outbound_minutes_per_month: 100, usage_thresholds: [80, 50, 100, 50]})
      {:ok, t} = Core.update_tenant(t, %{plan_id: plan.id}, @actor)
      assert Core.get_plan!(plan.id).usage_thresholds == [50, 80, 100]
      Events.subscribe(UsageThresholdReached)
      snap = Core.telephony_tenant(t.id)

      add = fn minutes ->
        Usage.add(t.id, "local", minutes * 60, DateTime.utc_now())
        UsageAlerts.after_call(snap, minutes * 60)
      end

      add.(40)
      refute_receive {:event, %UsageThresholdReached{}}, 50
      add.(45)
      assert_receive {:event, %UsageThresholdReached{percent: 50}}
      assert_receive {:event, %UsageThresholdReached{percent: 80, used: 85, allowed: 100} = u}
      refute_receive {:event, %UsageThresholdReached{}}, 50
      add.(1)
      refute_receive {:event, %UsageThresholdReached{}}, 50

      run(u)
      a = alert("usage:outbound_minutes_per_month:#{u.period_end}:80")
      assert %{kind: "usage_threshold", severity: "info", state: "resolved"} = a
      assert a.message =~ "85 of 100" and a.message =~ "15 minutes are left"

      add.(20)
      assert_receive {:event, %UsageThresholdReached{percent: 100} = full}
      run(full)

      assert %{severity: "critical", message: m} =
               alert("usage:outbound_minutes_per_month:#{full.period_end}:100")

      assert m =~ "emergency numbers still work"

      # A tenant's own thresholds win over the plan's.
      {:ok, t2} = Core.update_tenant(t, %{usage_thresholds: [10]}, @actor)
      assert Core.usage_thresholds(t2) == [10]
    end

    test "small allowances count minutes to a tenth", %{t: t} do
      plan = plan_fixture(%{outbound_minutes_per_month: 1, usage_thresholds: [50]})
      {:ok, t} = Core.update_tenant(t, %{plan_id: plan.id}, @actor)
      Events.subscribe(UsageThresholdReached)
      Usage.add(t.id, "local", 40, DateTime.utc_now())
      UsageAlerts.after_call(Core.telephony_tenant(t.id), 40)
      assert_receive {:event, %UsageThresholdReached{percent: 50, used: 0.7} = u}
      run(u)

      assert Repo.one(from a in Alert, where: a.kind == "usage_threshold").message =~
               "0.7 of 1 outbound minutes used this month (50%). 0.3 minutes are left"
    end

    test "limit reached, monthly summary", %{t: t} do
      run(%LimitReached{
        tenant_id: t.id,
        limit: "minutes_international_per_day",
        detail: "60 of 60 minutes",
        at: @now
      })

      assert %{kind: "limit_reached", severity: "critical"} =
               Repo.one(from a in Alert, where: a.kind == "limit_reached")

      run(%UsageSummary{
        tenant_id: t.id,
        month: "2026-10",
        totals: %{"outbound" => %{calls: 3, answered: 2, minutes: 9}},
        at: @now
      })

      assert %{kind: "usage_summary", message: "outbound: 3 calls, 2 answered, 9 minutes"} =
               alert("summary:2026-10")
    end
  end

  describe "operations and personal" do
    test "a phone offline longer than the set time; back before it: nothing; back after: resolved",
         %{t: t, admin: admin} do
      old = Application.get_env(:qpbx, QPBX.Notify)
      Application.put_env(:qpbx, QPBX.Notify, offline_ms: 100)
      on_exit(fn -> Application.put_env(:qpbx, QPBX.Notify, old || []) end)
      start_supervised!(Sources)
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), Process.whereis(Sources))

      reg = fn type, device ->
        Events.publish(%ExtensionRegistration{
          type: type,
          reason: "expired",
          tenant_id: t.id,
          extension_id: Ecto.UUID.generate(),
          extension: "101",
          device: device,
          at: DateTime.utc_now()
        })
      end

      reg.("unregistered", "101-desk")
      reg.("registered", "101-desk")
      Process.sleep(200)
      assert alert("offline:101-desk") == nil

      reg.("unregistered", "101-desk")
      Process.sleep(250)
      assert %{kind: "device_offline", state: "open"} = alert("offline:101-desk")
      reg.("registered", "101-desk")
      :sys.get_state(Sources)
      assert %{state: "resolved"} = alert("offline:101-desk")
      _ = admin
    end

    test "a webhook given up", %{t: t} do
      run(%WebhookDeadLettered{
        tenant_id: t.id,
        endpoint_id: "e1",
        delivery_id: "d1",
        event_type: "call.ended",
        url: "https://x.test/h",
        at: @now
      })

      assert %{kind: "webhook_dead", category: "operations"} = alert("webhook:e1")
    end

    test "missed calls and voicemail go to the user of the extension", %{t: t, admin: admin} do
      scope = Core.scope_for(admin)
      {:ok, ext} = Core.create_extension(scope, %{number: "101", name: "Dana"}, @actor)

      {:ok, dana} =
        Core.invite_user(
          scope,
          %{name: "Dana", email: "dana#{unique()}@x.test", extension_id: ext.id},
          @actor
        )

      run(%CallEvent{
        type: "missed",
        tenant_id: t.id,
        call_id: "c1",
        from: "+97250",
        extension_ids: [ext.id, Ecto.UUID.generate()],
        at: @now
      })

      assert [%{alert: %{kind: "missed_call", title: "Missed call from +97250"}}] =
               Notify.list_notifications(dana)

      run(%VoicemailReceived{
        tenant_id: t.id,
        voicemail_id: Ecto.UUID.generate(),
        extension_id: ext.id,
        caller_number: "+97250",
        duration: 7,
        at: @now
      })

      assert [%{alert: %{kind: "voicemail"}}, _] = Notify.list_notifications(dana)
      assert Notify.list_notifications(admin) == []
    end
  end
end
