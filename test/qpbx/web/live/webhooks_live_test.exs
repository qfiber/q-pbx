defmodule QPBX.Web.WebhooksLiveTest do
  use QPBX.Web.ConnCase, async: false
  use Oban.Testing, repo: QPBX.Repo
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.{Core, Integrations}

  setup do
    old = Application.get_env(:qpbx, QPBX.Integrations)
    # A public address that never needs to answer here: deliveries are not run in these tests.
    Application.put_env(:qpbx, QPBX.Integrations, [])
    on_exit(fn -> Application.put_env(:qpbx, QPBX.Integrations, old || []) end)
    :ok
  end

  defp signed_in(conn, account) do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, ~p"/login", login: %{email: account.email, password: password()})
    recycle(post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)}))
  end

  test "a tenant admin adds a webhook (secret once), changes it, sees and resends deliveries", %{
    conn: conn
  } do
    t = tenant_fixture()
    admin = user_fixture(t, "tenant_admin")
    conn = signed_in(conn, admin)
    {:ok, view, _} = live(conn, ~p"/app/webhooks")

    html =
      view
      |> form("#webhook-form",
        endpoint: %{url: "http://1.1.1.1/x", event_types: ["call.started"]}
      )
      |> render_submit()

    assert html =~ "must start with https://"

    html =
      view
      |> form("#webhook-form",
        endpoint: %{url: "https://10.0.0.8/x", event_types: ["call.started"]}
      )
      |> render_submit()

    assert html =~ "points to an internal address"

    view
    |> form("#webhook-form",
      endpoint: %{url: "https://1.1.1.1/hook", event_types: ["call.started", "call.ended"]}
    )
    |> render_submit()

    secret =
      view
      |> element("#webhook-secret-value")
      |> render()
      |> then(&Regex.run(~r/whsec_[\w-]+/, &1))
      |> hd()

    [e] = Integrations.list_webhooks(Core.scope_for(admin))
    assert e.event_types == ["call.started", "call.ended"]

    # The endpoint's page never shows the secret again.
    :ok =
      Integrations.Webhooks.dispatch(%QPBX.Events.CallEvent{
        type: "started",
        tenant_id: t.id,
        call_id: "c9",
        at: DateTime.utc_now()
      })

    {:ok, view, html} = live(conn, ~p"/app/webhooks/#{e.id}")
    refute html =~ secret
    assert html =~ "call.started"

    [d] = Integrations.list_webhook_deliveries(Core.scope_for(admin), e)
    view |> element("#open-#{d.id}") |> render_click()
    assert view |> element("#delivery-#{d.id}") |> render() =~ "c9"
    view |> element("#resend-#{d.id}") |> render_click()
    assert length(Integrations.list_webhook_deliveries(Core.scope_for(admin), e)) == 2

    view |> element("#toggle") |> render_click()
    refute Integrations.get_webhook(Core.scope_for(admin), e.id).enabled
    view |> element("#rotate") |> render_click()
    assert render(view) =~ "whsec_"
    view |> element("#delete") |> render_click()
    assert Integrations.list_webhooks(Core.scope_for(admin)) == []
  end

  test "tenant users cannot open webhooks", %{conn: conn} do
    user = user_fixture(tenant_fixture(), "tenant_user")
    assert {:error, {:redirect, %{to: "/app"}}} = live(signed_in(conn, user), ~p"/app/webhooks")
  end
end
