defmodule QPBX.Web.ApiKeysLiveTest do
  use QPBX.Web.ConnCase, async: true
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.Core

  defp signed_in(conn, account, login_path \\ ~p"/login") do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, login_path, login: %{email: account.email, password: password()})
    conn = post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)})
    recycle(conn)
  end

  defp create(view, scopes) do
    view
    |> form("#api-key-form", api_key: %{name: "CRM", scopes: scopes, expires_in: "30"})
    |> render_submit()

    view
    |> element("#new-token-value")
    |> render()
    |> then(&Regex.run(~r/qpbx_[\w-]+/, &1))
    |> hd()
  end

  test "a tenant admin creates a key (shown once), it works, then revokes it", %{conn: conn} do
    admin = user_fixture(tenant_fixture(), "tenant_admin")
    conn = signed_in(conn, admin)
    {:ok, view, _} = live(conn, ~p"/app/api-keys")

    assert view
           |> form("#api-key-form", api_key: %{name: "CRM", scopes: [""], expires_in: "30"})
           |> render_submit() =~ "pick at least one scope"

    token = create(view, ["read"])
    assert {:ok, key} = Core.authenticate_api_key(token)
    assert key.tenant_id == admin.tenant_id
    assert key.scopes == ["read"]

    # Reloaded, the page lists the key by its prefix only.
    {:ok, view, html} = live(conn, ~p"/app/api-keys")
    refute html =~ token
    assert html =~ key.prefix

    view |> element("#revoke-#{key.id}") |> render_click()
    assert {:error, :invalid} = Core.authenticate_api_key(token)
  end

  test "a tenant user cannot open the page", %{conn: conn} do
    user = user_fixture(tenant_fixture(), "tenant_user")
    assert {:error, {:redirect, %{to: "/app"}}} = live(signed_in(conn, user), ~p"/app/api-keys")
  end

  test "a platform admin creates a platform key", %{conn: conn} do
    conn = signed_in(conn, platform_admin_fixture(), ~p"/platform/login")
    {:ok, view, _} = live(conn, ~p"/platform/api-keys")
    token = create(view, ["read", "admin"])
    assert {:ok, %{tenant_id: nil, scopes: ["read", "admin"]}} = Core.authenticate_api_key(token)
  end
end
