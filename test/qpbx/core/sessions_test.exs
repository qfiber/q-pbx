defmodule QPBX.Core.SessionsTest do
  use QPBX.DataCase, async: false
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Core.{Sessions, UserSession}
  alias QPBX.Events.SessionsRevoked

  defp age(session, field, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)
    Repo.update!(Ecto.Changeset.change(session, [{field, at}]))
  end

  test "a new session is found by its token; only the token's hash is stored" do
    user = user_fixture()
    {token, session} = Core.create_session(user, %{ip: "203.0.113.5", user_agent: "test"})
    assert {:ok, %{id: id}, %UserSession{id: sid}} = Core.fetch_session(token)
    assert id == user.id and sid == session.id
    refute Repo.get!(UserSession, session.id).token_hash == token
    assert :error = Core.fetch_session(token <> "x")
    assert :error = Core.fetch_session(nil)
  end

  test "ends after the idle timeout, and the row is removed" do
    {token, session} = Core.create_session(user_fixture())
    age(session, :last_seen_at, Sessions.idle_timeout() + 1)
    assert :error = Core.fetch_session(token)
    refute Repo.get(UserSession, session.id)
  end

  test "ends 12 hours after login even when active" do
    {token, session} = Core.create_session(user_fixture())

    Repo.update!(
      Ecto.Changeset.change(session,
        expires_at: DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)
      )
    )

    assert :error = Core.fetch_session(token)
  end

  test "the idle timeout can be lowered but never set above 15 minutes" do
    Application.put_env(:qpbx, :session_idle_timeout, 3600)
    on_exit(fn -> Application.delete_env(:qpbx, :session_idle_timeout) end)
    assert Sessions.idle_timeout() == 900
    Application.put_env(:qpbx, :session_idle_timeout, 300)
    assert Sessions.idle_timeout() == 300
  end

  test "activity is recorded, but not on every request" do
    {token, session} = Core.create_session(user_fixture())
    old = age(session, :last_seen_at, 60)
    {:ok, _, touched} = Core.fetch_session(token)
    assert DateTime.compare(touched.last_seen_at, old.last_seen_at) == :gt
    {:ok, _, again} = Core.fetch_session(token)
    assert again.last_seen_at == touched.last_seen_at
    # A check that is not user activity does not extend the session.
    age(touched, :last_seen_at, 60)
    {:ok, _, untouched} = Core.fetch_session(token, touch: false)
    assert DateTime.diff(DateTime.utc_now(), untouched.last_seen_at) >= 59
  end

  test "revoking all sessions except one, audited, with an event" do
    QPBX.Events.subscribe(SessionsRevoked)
    user = user_fixture()
    {keep_token, keep} = Core.create_session(user)
    {t2, s2} = Core.create_session(user)
    {t3, _} = Core.create_session(user)

    assert {:ok, 2} = Core.revoke_sessions(user, user, except: keep.id)
    assert {:ok, _, _} = Core.fetch_session(keep_token)
    assert :error = Core.fetch_session(t2)
    assert :error = Core.fetch_session(t3)
    assert_receive {:event, %SessionsRevoked{session_ids: ids}}
    assert s2.id in ids and length(ids) == 2

    assert Repo.exists?(
             from a in QPBX.Core.AuditLog,
               where:
                 a.action == "session.revoke_all" and a.target_id == ^user.id and
                   a.actor_type == "user"
           )
  end

  test "an account cannot revoke another account's session" do
    a = user_fixture()
    {_, other} = Core.create_session(user_fixture())
    assert {:ok, 0} = Core.revoke_session(a, other.id, a)
    assert Repo.get(UserSession, other.id)
  end

  test "changing the password or turning on 2FA ends every session" do
    user = user_fixture()
    {t1, _} = Core.create_session(user)

    {:ok, user} =
      Core.complete_setup(user, %{
        password: "a new password 123",
        password_confirmation: "a new password 123"
      })

    assert :error = Core.fetch_session(t1)

    {t2, _} = Core.create_session(user)
    secret = Core.new_totp_secret()
    {:ok, _} = Core.enable_totp(user, secret, totp_code(secret))
    assert :error = Core.fetch_session(t2)
  end

  test "the sweeper ends idle sessions and announces them" do
    QPBX.Events.subscribe(SessionsRevoked)
    {_, idle} = Core.create_session(user_fixture())
    {live_token, _} = Core.create_session(user_fixture())
    age(idle, :last_seen_at, Sessions.idle_timeout() + 5)
    assert Sessions.sweep() == 1
    assert_receive {:event, %SessionsRevoked{session_ids: [id]}}
    assert id == idle.id
    assert {:ok, _, _} = Core.fetch_session(live_token)
  end
end
