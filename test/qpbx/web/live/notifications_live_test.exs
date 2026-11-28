defmodule QPBX.Web.NotificationsLiveTest do
  use QPBX.Web.ConnCase, async: false
  use Oban.Testing, repo: QPBX.Repo
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.{Core, Notify}
  alias QPBX.Notify.Alerts.Alert

  defp signed_in(conn, account, path \\ ~p"/login") do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, path, login: %{email: account.email, password: password()})
    recycle(post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)}))
  end

  setup do
    t = tenant_fixture()
    admin = user_fixture(t, "tenant_admin")
    %{t: t, admin: admin}
  end

  defp alert(t, kind, key),
    do:
      Notify.raise_alert(%{
        kind: kind,
        key: key,
        tenant_id: t.id,
        title: "Title #{key}",
        message: "Message #{key}"
      })

  test "an alert told three times is one row, ×3; marking it read marks all three", %{
    conn: conn,
    t: t,
    admin: admin
  } do
    import Ecto.Query
    {:ok, a} = alert(t, "brute_force", "bf1")

    for _ <- 1..2 do
      QPBX.Repo.update_all(from(x in Alert, where: x.id == ^a.id),
        set: [notified_at: DateTime.add(DateTime.utc_now(), -16 * 60)]
      )

      {:ok, _} = alert(t, "brute_force", "bf1")
    end

    assert length(Notify.list_notifications(admin)) == 3
    {:ok, view, html} = live(signed_in(conn, admin), ~p"/app/notifications")
    assert html =~ "×3"

    assert [row] =
             view |> element("#notifications") |> render() |> String.split(~s(id="n-)) |> tl()

    [latest | _] = Notify.list_notifications(admin)
    view |> element("#read-#{latest.id}") |> render_click()
    assert Notify.unread_count(admin) == 0
    _ = row
  end

  test "the bell counts unread notifications and updates live; read and acknowledge on the page",
       %{conn: conn, t: t, admin: admin} do
    conn = signed_in(conn, admin)
    {:ok, page, html} = live(conn, ~p"/app/extensions")
    refute html =~ ~s(id="bell-count")

    {:ok, _} = alert(t, "fraud_block", "f1")
    assert render(page) =~ ~r{id="bell-count"[^>]*>\s*1\s*<}

    {:ok, view, html} = live(conn, ~p"/app/notifications")
    assert html =~ "Title f1" and html =~ "Message f1"
    [n] = Notify.list_notifications(admin)
    view |> element("#ack-#{n.id}") |> render_click()
    assert [%{state: "acknowledged"}] = Notify.list_alerts(Core.scope_for(admin))
    view |> element("#read-#{n.id}") |> render_click()
    assert Notify.unread_count(admin) == 0
    refute render(page) =~ ~s(id="bell-count")
  end

  test "settings: channels per category and quiet hours are saved", %{conn: conn, admin: admin} do
    {:ok, view, _} = live(signed_in(conn, admin), ~p"/app/notifications")

    view
    |> form("#settings-form",
      settings: %{
        channels: %{"security" => ["portal"], "usage" => ["", "email"]},
        quiet_start: "22",
        quiet_end: "7",
        timezone: "Asia/Jerusalem"
      }
    )
    |> render_submit()

    pref = Notify.my_preference(admin)
    assert pref.channels["security"] == ["portal"] and pref.channels["usage"] == ["email"]
    assert {pref.quiet_start, pref.quiet_end, pref.timezone} == {22, 7, "Asia/Jerusalem"}
  end

  test "tenant admins: alerts, delivery log, resend, test, shared recipients; users cannot open it",
       %{conn: conn, t: t, admin: admin} do
    conn = signed_in(conn, admin)
    {:ok, a} = alert(t, "fraud_block", "f9")
    {:ok, view, html} = live(conn, ~p"/app/alerts")
    assert html =~ "Title f9"
    view |> element("#open-#{a.id}") |> render_click()
    assert render(view) =~ admin.email

    email =
      Enum.find(
        Notify.list_alert_deliveries(Core.scope_for(admin), a.id),
        &(&1.channel == "email")
      )

    view |> element("#resend-#{email.id}") |> render_click()
    assert length(Notify.list_alert_deliveries(Core.scope_for(admin), a.id)) == 3

    view |> element("#resolve-#{a.id}") |> render_click()

    assert [%{state: "resolved"}] =
             Notify.list_alerts(Core.scope_for(admin), %{"state" => "resolved"})

    view |> form("#test-form", test: %{category: "operations"}) |> render_submit()
    assert Enum.any?(Notify.list_alerts(Core.scope_for(admin)), &(&1.kind == "test"))

    view
    |> form("#channel-form",
      channel: %{
        kind: "email",
        address: "it@acme.test",
        categories: ["security"],
        min_severity: "info"
      }
    )
    |> render_submit()

    assert [%{address: "it@acme.test"}] = Notify.list_alert_channels(Core.scope_for(admin))

    user = user_fixture(t, "tenant_user")

    assert {:error, {:redirect, %{to: "/app"}}} =
             live(signed_in(build_conn(), user), ~p"/app/alerts")

    refute html =~ "Mandatory categories"
  end

  test "platform admins set mandatory categories and see the platform's page", %{conn: conn} do
    padmin = platform_admin_fixture()
    {:ok, view, html} = live(signed_in(conn, padmin, ~p"/platform/login"), ~p"/platform/alerts")
    assert html =~ "Mandatory categories"

    view
    |> form("#mandatory-form", m: %{categories: ["", "security", "health"]})
    |> render_submit()

    assert Enum.sort(Notify.mandatory_categories()) == ["health", "security"]
  end

  test "the email's acknowledge link: a page with a button, then acknowledged; a bad link refused",
       %{conn: conn, t: t} do
    {:ok, a} = alert(t, "fraud_block", "f5")
    [job] = all_enqueued(worker: QPBX.Notify.AlertEmail)
    link = job.args["notification_id"] <> "." <> job.args["token"]

    html = conn |> get(~p"/alerts/ack/#{link}") |> html_response(200)
    assert html =~ ~s(id="ack-form")
    assert [%{state: "open"}] = Notify.list_alerts(Core.scope_for(user_fixture(t)))

    html =
      build_conn() |> post(~p"/alerts/ack/#{link}") |> html_response(200)

    assert html =~ ~s(id="ack-done")
    assert QPBX.Repo.get!(QPBX.Notify.Alerts.Alert, a.id).state == "acknowledged"

    bad = link <> "x"
    assert build_conn() |> post(~p"/alerts/ack/#{bad}") |> html_response(404) =~ "not valid"
  end
end
