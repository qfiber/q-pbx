defmodule QPBX.Core.LoginGuardTest do
  use QPBX.DataCase, async: true
  import QPBX.Fixtures
  alias QPBX.Core.LoginGuard
  alias QPBX.Core.LoginGuard.Failure

  defp ip,
    do:
      {10, 9, rem(System.unique_integer([:positive]), 250),
       rem(System.unique_integer([:positive]), 250)}

  defp key(ip), do: "ip:" <> to_string(:inet.ntoa(ip))
  defp fail(ip, n), do: Enum.map(1..n, fn _ -> LoginGuard.failure(ip) end) |> List.last()

  defp hours_until(%DateTime{} = t),
    do: Float.round(DateTime.diff(t, DateTime.utc_now()) / 3600, 1)

  defp expire_block(ip) do
    f = Repo.get!(Failure, key(ip))

    Repo.update!(
      Ecto.Changeset.change(f,
        blocked_until: DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)
      )
    )
  end

  test "5 failures block the IP for 1 hour, 5 more for 24 hours" do
    ip = ip()
    assert fail(ip, 4) == :ok
    assert LoginGuard.check(ip) == :ok
    assert {:blocked, until} = LoginGuard.failure(ip)
    assert hours_until(until) == 1.0
    assert {:blocked, _} = LoginGuard.check(ip)

    expire_block(ip)
    assert LoginGuard.check(ip) == :ok
    assert fail(ip, 4) == :ok
    assert {:blocked, until} = LoginGuard.failure(ip)
    assert hours_until(until) == 24.0
  end

  test "other IPs are not affected" do
    a = ip()
    fail(a, 5)
    assert LoginGuard.check(ip()) == :ok
  end

  test "a success clears the failure count; strikes are forgotten after a quiet day" do
    ip = ip()
    fail(ip, 4)
    LoginGuard.success(ip)
    assert fail(ip, 4) == :ok

    fail(ip, 1)
    expire_block(ip)
    f = Repo.get!(Failure, key(ip))

    Repo.update!(
      Ecto.Changeset.change(f,
        last_failure_at:
          DateTime.utc_now() |> DateTime.add(-25 * 3600) |> DateTime.truncate(:second)
      )
    )

    # After a quiet day the next round of 5 is a first strike again (1 hour).
    {:blocked, until} = fail(ip, 5)
    assert hours_until(until) == 1.0
  end

  test "accounts are never blocked, but 5 failures write an alert entry" do
    user = user_fixture()
    Enum.each(1..5, fn _ -> LoginGuard.failure(ip(), user) end)

    assert Repo.exists?(
             from a in QPBX.Core.AuditLog,
               where: a.action == "account.login_failures_alert" and a.target_id == ^user.id
           )
  end

  test "IPv6 addresses work too" do
    ip = {0x2001, 0xDB8, 0, 0, 0, 0, 0, System.unique_integer([:positive])}
    assert {:blocked, _} = fail(ip, 5)
  end
end
