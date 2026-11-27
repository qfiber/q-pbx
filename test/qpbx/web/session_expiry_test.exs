defmodule QPBX.Web.SessionExpiryTest do
  # Not async: changes global app config.
  use QPBX.Web.ConnCase, async: false
  import QPBX.Fixtures

  test "sessions expire after :session_max_age", %{conn: conn} do
    user = user_fixture()
    conn = post(conn, ~p"/login", login: %{email: user.email, password: password()})
    assert redirected_to(conn) == ~p"/app"
    conn = recycle(conn)
    assert get(conn, ~p"/app").status == 200

    Application.put_env(:qpbx, :session_max_age, -1)
    on_exit(fn -> Application.delete_env(:qpbx, :session_max_age) end)
    assert get(conn, ~p"/app") |> redirected_to() == ~p"/login"
  end
end
