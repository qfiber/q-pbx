defmodule QPBX.Web.SessionsWebTest do
  use QPBX.Web.ConnCase, async: false
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.Core

  defp log_in(conn, user \\ user_fixture(tenant_fixture(), "tenant_user")) do
    conn = post(conn, ~p"/login", login: %{email: user.email, password: password()})
    assert redirected_to(conn) == ~p"/app"
    {recycle(conn), user}
  end

  test "the cookie holds only a session token, and logout ends the session", %{conn: conn} do
    {conn, user} = log_in(conn)
    session = get_session(get(conn, ~p"/app"))
    assert is_binary(session["session_token"])
    refute Map.has_key?(session, "account")
    assert [_] = Core.list_sessions(user)

    conn = delete(conn, ~p"/logout")
    assert Core.list_sessions(user) == []
    assert get(recycle(conn), ~p"/app") |> redirected_to() == ~p"/login"
  end

  test "a revoked session loses access on its next request", %{conn: conn} do
    {conn, user} = log_in(conn)
    assert get(conn, ~p"/app").status == 200
    {:ok, 1} = Core.revoke_sessions(user, {:system, "test"})
    assert get(conn, ~p"/app") |> redirected_to() == ~p"/login"
  end

  # The socket-level disconnect itself is Phoenix's (checked in the lab with a real browser);
  # here: revocation broadcasts "disconnect" on the session's live socket topic.
  test "revoking a session tells its open live pages to disconnect", %{conn: conn} do
    {_conn, user} = log_in(conn)
    [session] = Core.list_sessions(user)
    QPBX.Web.Endpoint.subscribe(QPBX.Web.Auth.socket_id(session.id))
    {:ok, 1} = Core.revoke_sessions(user, {:system, "test"})
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 2000
  end

  test "an action on a live page after revocation sends the user to log in", %{conn: conn} do
    {conn, user} = log_in(conn)
    {:ok, view, _} = live(conn, ~p"/app/account")
    # Revoke without the broadcast reaching this page (as from the CLI on another node).
    QPBX.Repo.delete_all(QPBX.Core.UserSession)

    assert {:error, {:redirect, %{to: "/login"}}} =
             view |> element("#revoke-others") |> render_click()

    _ = user
  end

  test "the account page lists sessions and signs out the others", %{conn: conn} do
    user = user_fixture(tenant_fixture(), "tenant_user")
    {conn, _} = log_in(conn, user)
    {other_conn, _} = log_in(build_conn(), user)
    {:ok, view, html} = live(conn, ~p"/app/account")
    assert html =~ "This browser"
    assert length(Core.list_sessions(user)) == 2

    view |> element("#revoke-others") |> render_click()
    assert [_] = Core.list_sessions(user)
    assert get(other_conn, ~p"/app") |> redirected_to() == ~p"/login"
  end
end
