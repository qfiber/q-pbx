defmodule QPBX.Web.LoginProtectionTest do
  use QPBX.Web.ConnCase, async: false
  import QPBX.Fixtures

  defp from(conn, ip), do: %{conn | remote_ip: ip}

  defp attempt(ip, email, password) do
    build_conn() |> from(ip) |> post(~p"/login", login: %{email: email, password: password})
  end

  test "5 failed logins from one IP block it (HTTP 429), even with the right password next" do
    user = user_fixture(tenant_fixture(), "tenant_user")
    ip = {198, 51, 100, 21}

    for _ <- 1..4,
        do:
          assert(
            html_response(attempt(ip, user.email, "wrong password!!"), 200) =~
              "Wrong email or password"
          )

    assert html_response(attempt(ip, user.email, "wrong password!!"), 429) =~
             "Too many failed attempts"

    assert attempt(ip, user.email, password()).status == 429
    assert build_conn() |> from(ip) |> get(~p"/login") |> Map.get(:status) == 429

    # Another IP, same account: the account itself is never locked.
    assert redirected_to(attempt({198, 51, 100, 22}, user.email, password())) == ~p"/app"
  end

  test "wrong 2FA codes count too" do
    {:ok, user} =
      QPBX.Core.create_user(
        tenant_fixture(),
        %{email: "c@x.test", name: "C"},
        "tenant_user",
        {:system, "t"}
      )

    {:ok, user} =
      QPBX.Core.complete_setup(user, %{password: password(), password_confirmation: password()})

    secret = QPBX.Core.new_totp_secret()
    {:ok, _} = QPBX.Core.enable_totp(user, secret, totp_code(secret))
    ip = {198, 51, 100, 23}
    conn = attempt(ip, user.email, password())
    assert redirected_to(conn) == ~p"/2fa"

    conn =
      Enum.reduce(1..4, recycle(conn), fn _, c ->
        c |> from(ip) |> post(~p"/2fa", totp: %{code: "000000"}) |> recycle()
      end)

    assert conn |> from(ip) |> post(~p"/2fa", totp: %{code: "000000"}) |> Map.get(:status) == 429
  end

  test "bad setup links count as failures" do
    ip = {198, 51, 100, 24}
    for _ <- 1..4, do: build_conn() |> from(ip) |> get("/setup/bogus-token")
    assert build_conn() |> from(ip) |> get("/setup/bogus-token") |> Map.get(:status) == 429
  end

  test "IPs on the platform HTTPS allowlist are never blocked" do
    {:ok, _} =
      QPBX.Firewall.create_entry(
        %{
          level: "platform",
          kind: "allow",
          scope: "all",
          cidr: "198.51.100.0/28",
          reason: "office"
        },
        {:system, "t"}
      )

    _ = QPBX.Firewall.sync_status()
    user = user_fixture(tenant_fixture(), "tenant_user")
    ip = {198, 51, 100, 5}
    for _ <- 1..7, do: attempt(ip, user.email, "wrong password!!")
    assert redirected_to(attempt(ip, user.email, password())) == ~p"/app"
  end

  describe "with the built-in proof of work" do
    setup do
      old = Application.get_env(:qpbx, QPBX.Web.Captcha)
      Application.put_env(:qpbx, QPBX.Web.Captcha, provider: :pow)
      on_exit(fn -> Application.put_env(:qpbx, QPBX.Web.Captcha, old) end)
    end

    test "the login form carries a challenge, and a login without the answer fails" do
      user = user_fixture(tenant_fixture(), "tenant_user")
      ip = {198, 51, 100, 30}
      html = build_conn() |> from(ip) |> get(~p"/login") |> html_response(200)
      assert html =~ "data-pow-challenge"

      assert html_response(attempt(ip, user.email, password()), 200) =~
               "automatic check did not pass"
    end

    test "a login with a solved challenge goes through" do
      user = user_fixture(tenant_fixture(), "tenant_user")
      ch = QPBX.Web.Captcha.Pow.challenge()

      n =
        Enum.find(
          0..ch.maxnumber,
          &(Base.encode16(:crypto.hash(:sha256, ch.salt <> Integer.to_string(&1)), case: :lower) ==
              ch.challenge)
        )

      pow =
        Base.encode64(
          Jason.encode!(%{
            algorithm: ch.algorithm,
            challenge: ch.challenge,
            number: n,
            salt: ch.salt,
            signature: ch.signature
          })
        )

      conn =
        build_conn()
        |> from({198, 51, 100, 31})
        |> post(~p"/login", login: %{email: user.email, password: password()}, pow: pow)

      assert redirected_to(conn) == ~p"/app"
    end
  end
end
