defmodule QPBX.Notify.AlertsTest do
  use QPBX.DataCase, async: false
  use Oban.Testing, repo: QPBX.Repo
  import Swoosh.TestAssertions
  import QPBX.Fixtures
  alias QPBX.{Core, Notify}
  alias QPBX.Notify.{AlertEmail, AlertWebhook}
  alias QPBX.Notify.Alerts.{Alert, Notification}

  @actor {:system, "test"}

  setup do
    t = tenant_fixture()
    admin = user_fixture(t, "tenant_admin")
    user = user_fixture(t, "tenant_user")
    padmin = platform_admin_fixture()
    %{t: t, admin: admin, user: user, padmin: padmin, scope: Core.scope_for(admin)}
  end

  defp raise_alert(t, kind, key, extra \\ %{}),
    do:
      Notify.raise_alert(
        Map.merge(
          %{kind: kind, key: key, tenant_id: t.id, title: "T #{key}", message: "M #{key}"},
          extra
        )
      )

  defp to(account, channel \\ "portal"),
    do:
      Repo.all(
        from n in Notification,
          where: n.account_id == ^account.id and n.channel == ^channel,
          order_by: n.inserted_at
      )

  test "an alert reaches its audience by role, on the channels the severity calls for", %{
    t: t,
    admin: admin,
    user: user,
    padmin: padmin
  } do
    {:ok, a} = raise_alert(t, "fraud_block", "fraud:1")
    assert %{category: "security", severity: "critical", state: "open"} = a

    # Critical: portal and email to the tenant's admins; not to tenant users, nor platform
    # admins (not in its audience).
    assert [%{event: "raised", status: "sent"}] = to(admin)
    assert [%{event: "raised", address: email}] = to(admin, "email")
    assert email == admin.email
    assert to(user) == [] and to(padmin) == []
    assert [_] = all_enqueued(worker: AlertEmail)

    # Info alerts go to the portal only by default; usage reports also by email.
    {:ok, _} = raise_alert(t, "test", "test:1")
    assert length(to(admin)) == 2 and length(to(admin, "email")) == 1
    {:ok, _} = raise_alert(t, "usage_threshold", "usage:80")
    assert length(to(admin)) == 3 and length(to(admin, "email")) == 2

    # Platform alerts reach platform admins, never tenant admins.
    {:ok, _} =
      Notify.raise_alert(%{
        kind: "backup_failed",
        key: "backup:db",
        title: "Backup",
        message: "failed"
      })

    # (The test kind reached platform admins too.)
    assert [%{event: "raised"}, %{event: "raised"}] = to(padmin)
    assert length(to(admin)) == 3
  end

  test "repeats of an open key are grouped: one notice per 15 minutes with the count", %{
    t: t,
    admin: admin
  } do
    {:ok, a} = raise_alert(t, "brute_force", "bf:101")
    for _ <- 1..36, do: {:ok, _} = raise_alert(t, "brute_force", "bf:101")
    a = Repo.get!(Alert, a.id)
    assert a.count == 37 and a.repeats == 36
    assert length(to(admin)) == 1

    # Fifteen minutes later the next repeat tells everyone how many came since.
    Repo.update_all(from(x in Alert, where: x.id == ^a.id),
      set: [notified_at: DateTime.add(DateTime.utc_now(), -16 * 60)]
    )

    {:ok, _} = raise_alert(t, "brute_force", "bf:101")
    assert [_, %{event: "repeated"}] = to(admin)
    assert %{repeats: 0, count: 38} = Repo.get!(Alert, a.id)

    # Resolved, the key starts a new alert.
    {:ok, _} = Notify.resolve_alert(Core.scope_for(admin), a.id, admin)
    assert [_, _, %{event: "resolved"}] = to(admin)
    {:ok, b} = raise_alert(t, "brute_force", "bf:101")
    assert b.id != a.id
  end

  test "preferences per category; a mandatory category cannot be switched off", %{
    t: t,
    admin: admin,
    padmin: padmin
  } do
    {:ok, _} =
      Notify.save_my_preference(admin, %{channels: %{"security" => [], "usage" => ["email"]}})

    {:ok, _} = raise_alert(t, "fraud_block", "f:1")
    assert to(admin) == [] and to(admin, "email") == []
    # Email only for usage: a critical usage alert and an info threshold both arrive by email
    # (usage reports are what the email is for), nothing in the portal.
    {:ok, _} = raise_alert(t, "limit_reached", "u:1")
    assert to(admin) == []
    assert [_] = to(admin, "email")
    {:ok, _} = raise_alert(t, "usage_threshold", "u:2")
    assert to(admin) == [] and length(to(admin, "email")) == 2

    :ok = Notify.set_mandatory_categories(Core.scope_for(padmin), ["security"], padmin)
    {:ok, _} = raise_alert(t, "fraud_block", "f:2")
    assert [_] = to(admin)
    assert [_, _, _] = to(admin, "email")

    assert {:error, cs} = Notify.save_my_preference(admin, %{channels: %{"security" => ["sms"]}})
    assert %{channels: [_]} = errors_on(cs)
  end

  test "quiet hours hold back email but not critical alerts; the portal entry is always made", %{
    t: t,
    admin: admin
  } do
    {:ok, now} = DateTime.now(t.timezone)

    {:ok, _} =
      Notify.save_my_preference(admin, %{quiet_start: now.hour, quiet_end: rem(now.hour + 2, 24)})

    {:ok, _} = raise_alert(t, "device_offline", "off:1")
    assert [%{status: "skipped", reason: "quiet_hours"}] = to(admin, "email")
    assert [_] = to(admin)
    {:ok, _} = raise_alert(t, "fraud_block", "f:1")
    assert [_, %{status: "pending"}] = to(admin, "email")
  end

  test "each address gets at most 20 emails an hour", %{t: t, admin: admin} do
    for i <- 1..22, do: {:ok, _} = raise_alert(t, "device_offline", "off:#{i}")
    emails = to(admin, "email")
    assert Enum.count(emails, &(&1.status == "pending")) == 20
    assert Enum.count(emails, &(&1.reason == "rate_cap")) == 2
  end

  test "email: the recipient's language, an acknowledge link that works once; resolved says back to normal",
       %{t: t, admin: admin, scope: scope} do
    {:ok, a} = raise_alert(t, "fraud_block", "f:1")
    [job] = all_enqueued(worker: AlertEmail)
    assert :ok = perform_job(AlertEmail, job.args)

    assert_email_sent(fn email ->
      assert email.subject == "[Critical] T f:1"
      [link] = Regex.run(~r{/alerts/ack/(\S+)}, email.text_body, capture: :all_but_first)
      send(self(), {:link, link})
    end)

    assert_received {:link, link}
    assert [%{status: "sent"}] = to(admin, "email")

    assert {:ok, %{state: "acknowledged", acknowledged_by: "email: " <> _}} =
             Notify.acknowledge_by_token(link)

    assert {:error, :invalid} = Notify.acknowledge_by_token(link <> "x")
    assert {:error, :invalid} = Notify.acknowledge_by_token("nope")

    {:ok, _} = Notify.resolve_alert(scope, a.id, admin)

    job =
      Enum.find(all_enqueued(worker: AlertEmail), fn j ->
        Repo.get!(Notification, j.args["notification_id"]).event == "resolved"
      end)

    assert :ok = perform_job(AlertEmail, job.args)
    assert_email_sent(subject: "Back to normal: T f:1")
  end

  test "Arabic recipients get Arabic emails", %{t: t} do
    ar = user_fixture(t, "tenant_admin", %{locale: "ar"})
    {:ok, _} = raise_alert(t, "fraud_block", "f:ar")
    job = Enum.find(all_enqueued(worker: AlertEmail), &(&1.args["locale"] == "ar"))
    assert job
    :ok = perform_job(AlertEmail, job.args)
    assert_email_sent(fn email -> email.to == [{"", ar.email}] and email.subject =~ "حرج" end)
  end

  test "a hard bounce marks the email bounced and stops retrying", %{t: t, admin: admin} do
    defmodule Bouncer do
      use Swoosh.Adapter

      def deliver(_email, _config),
        do: {:error, {:send, {:permanent_failure, "mx.example", "550 no such user"}}}
    end

    old = Application.get_env(:qpbx, QPBX.Notify.Mailer)
    Application.put_env(:qpbx, QPBX.Notify.Mailer, adapter: Bouncer)
    on_exit(fn -> Application.put_env(:qpbx, QPBX.Notify.Mailer, old) end)

    {:ok, _} = raise_alert(t, "fraud_block", "f:b")
    [job] = all_enqueued(worker: AlertEmail)
    assert {:cancel, :bounced} = perform_job(AlertEmail, job.args)
    assert [%{status: "bounced", attempts: [%{"error" => err}]}] = to(admin, "email")
    assert err =~ "550"
  end

  test "shared recipients and alert webhooks by category and severity; generic and Alertmanager bodies",
       %{t: t, scope: scope} do
    old = Application.get_env(:qpbx, QPBX.Integrations)
    Application.put_env(:qpbx, QPBX.Integrations, [])
    on_exit(fn -> Application.put_env(:qpbx, QPBX.Integrations, old || []) end)

    {:ok, it, nil} =
      Notify.create_alert_channel(
        scope,
        %{kind: "email", address: "it@acme.test", categories: ["security"]},
        @actor
      )

    {:ok, hook, "whsec_" <> _} =
      Notify.create_alert_channel(
        scope,
        %{
          kind: "webhook",
          address: "https://1.1.1.1/hook",
          categories: ["security", "usage"],
          min_severity: "warning"
        },
        @actor
      )

    assert {:error, cs} =
             Notify.create_alert_channel(
               scope,
               %{kind: "webhook", address: "https://10.0.0.1/", categories: ["usage"]},
               @actor
             )

    assert %{address: ["points to an internal address"]} = errors_on(cs)

    assert {:error, cs} =
             Notify.create_alert_channel(
               scope,
               %{kind: "webhook", address: "http://1.1.1.1/", categories: ["usage"]},
               @actor
             )

    assert %{address: ["must start with https://"]} = errors_on(cs)

    {:ok, a} = raise_alert(t, "fraud_block", "f:1")

    sent =
      Repo.all(
        from n in Notification, where: n.alert_id == ^a.id and not is_nil(n.alert_channel_id)
      )

    assert Enum.sort(Enum.map(sent, &{&1.channel, &1.address})) == [
             {"email", "it@acme.test"},
             {"webhook", "https://1.1.1.1/hook"}
           ]

    # Info usage alerts are below the webhook's minimum severity, and not in it@'s categories.
    {:ok, u} = raise_alert(t, "usage_threshold", "u:1")

    assert Repo.all(
             from n in Notification, where: n.alert_id == ^u.id and not is_nil(n.alert_channel_id)
           ) == []

    note = Enum.find(sent, &(&1.channel == "webhook"))
    generic = AlertWebhook.payload("generic", note, a)

    assert %{type: "alert.raised", alert: %{key: "f:1", severity: "critical", state: "open"}} =
             generic

    am = AlertWebhook.payload("alertmanager", note, a)

    assert %{
             status: "firing",
             version: "4",
             alerts: [
               %{labels: %{alertname: "fraud_block", severity: "critical"}, fingerprint: fid}
             ]
           } = am

    assert fid == a.id

    # Another tenant sees none of these channels.
    other = Core.scope_for(user_fixture(tenant_fixture()))
    assert Notify.list_alert_channels(other) == []
    assert {:error, :not_found} = Notify.delete_alert_channel(other, it.id, @actor)
    _ = hook
  end

  test "alert webhooks: signed, retried, dead after 24 hours; resend", %{t: t, scope: scope} do
    old = Application.get_env(:qpbx, QPBX.Integrations)
    # Delivery refused (internal address) without a network: counts as a failure.
    Application.put_env(:qpbx, QPBX.Integrations, [])
    on_exit(fn -> Application.put_env(:qpbx, QPBX.Integrations, old || []) end)

    {:ok, _, _} =
      Notify.create_alert_channel(
        scope,
        %{kind: "webhook", address: "https://1.1.1.1/hook", categories: ["security"]},
        @actor
      )

    {:ok, a} = raise_alert(t, "fraud_block", "f:1")
    [job] = all_enqueued(worker: AlertWebhook)
    n = Repo.get!(Notification, job.args["notification_id"])

    Repo.update_all(from(x in QPBX.Notify.Alerts.Channel, where: x.id == ^n.alert_channel_id),
      set: [address: "https://127.0.0.1/hook"]
    )

    assert {:error, "refused: 127.0.0.1 is an internal address"} =
             perform_job(AlertWebhook, job.args, attempt: 1)

    assert %{status: "failed"} = Repo.get!(Notification, n.id)

    Repo.update_all(from(x in Notification, where: x.id == ^n.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -24 * 3600)]
    )

    assert {:cancel, :dead} = perform_job(AlertWebhook, job.args, attempt: 12)
    assert %{status: "dead", attempts: [_, _]} = Repo.get!(Notification, n.id)

    assert {:ok, copy} = Notify.resend_notification(scope, n.id, @actor)
    assert copy.id != n.id and copy.status == "pending"
    assert Enum.any?(all_enqueued(worker: AlertWebhook), &(&1.args["notification_id"] == copy.id))
    assert [_ | _] = Notify.list_alert_deliveries(scope, a.id)
    other = Core.scope_for(user_fixture(tenant_fixture()))
    assert {:error, :not_found} = Notify.resend_notification(other, n.id, @actor)
    assert Notify.list_alert_deliveries(other, a.id) == []
  end

  test "the bell: unread count, read one or all; alerts listed and filtered per scope", %{
    t: t,
    admin: admin,
    padmin: padmin,
    scope: scope
  } do
    Notify.raise_alert(%{
      kind: "usage_threshold",
      key: "u1",
      tenant_id: t.id,
      title: "U",
      message: "u"
    })

    Notify.raise_alert(%{
      kind: "fraud_block",
      key: "f1",
      tenant_id: t.id,
      title: "F",
      message: "f"
    })

    assert Notify.unread_count(admin) == 2
    [first | _] = Notify.list_notifications(admin)
    :ok = Notify.mark_read(admin, first.id)
    assert Notify.unread_count(admin) == 1
    :ok = Notify.mark_read(admin, :all)
    assert Notify.unread_count(admin) == 0

    assert [%{kind: "fraud_block"}] = Notify.list_alerts(scope, %{"severity" => "critical"})
    assert length(Notify.list_alerts(scope)) == 2
    assert Notify.list_alerts(Core.scope_for(user_fixture(tenant_fixture()))) == []
    assert length(Notify.list_alerts(Core.scope_for(padmin))) >= 2

    {:ok, _} = Notify.send_test_notification(scope, "operations", admin)
    assert Notify.unread_count(admin) == 1
  end
end
