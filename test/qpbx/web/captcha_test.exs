defmodule QPBX.Web.CaptchaTest do
  use ExUnit.Case, async: false
  alias QPBX.Web.Captcha
  alias QPBX.Web.Captcha.Pow

  @ip {203, 0, 113, 9}

  defp solve(%{salt: salt, challenge: c, maxnumber: max} = ch) do
    n =
      Enum.find(
        0..max,
        &(Base.encode16(:crypto.hash(:sha256, salt <> Integer.to_string(&1)), case: :lower) == c)
      )

    payload(ch, n)
  end

  defp payload(ch, n),
    do:
      Base.encode64(
        Jason.encode!(%{
          algorithm: ch.algorithm,
          challenge: ch.challenge,
          number: n,
          salt: ch.salt,
          signature: ch.signature
        })
      )

  describe "built-in proof of work" do
    test "a solved challenge passes once" do
      answer = solve(Pow.challenge())
      assert :ok = Pow.verify(%{"pow" => answer}, @ip)
      assert {:error, :invalid} = Pow.verify(%{"pow" => answer}, @ip)
    end

    test "wrong number, tampered signature, expired or missing answers fail" do
      ch = Pow.challenge()
      good = solve(ch)
      n = Jason.decode!(Base.decode64!(good))["number"]
      assert {:error, :invalid} = Pow.verify(%{"pow" => payload(ch, n + 1)}, @ip)

      assert {:error, :invalid} =
               Pow.verify(
                 %{"pow" => payload(%{ch | signature: String.duplicate("0", 64)}, n)},
                 @ip
               )

      expired_salt = String.replace(ch.salt, ~r/expires=\d+/, "expires=1")

      assert {:error, :invalid} =
               Pow.verify(%{"pow" => payload(%{ch | salt: expired_salt}, n)}, @ip)

      assert {:error, :missing} = Pow.verify(%{}, @ip)
      assert {:error, :invalid} = Pow.verify(%{"pow" => "not base64!"}, @ip)
    end
  end

  describe "outside services" do
    setup do
      old = Application.get_env(:qpbx, Captcha)
      on_exit(fn -> Application.put_env(:qpbx, Captcha, old) end)

      set = fn provider ->
        Application.put_env(:qpbx, Captcha,
          provider: provider,
          site_key: "site",
          secret: "secret",
          req_options: [plug: {Req.Test, __MODULE__}]
        )
      end

      %{set: set}
    end

    test "Turnstile sends secret, token and IP; success decides", %{set: set} do
      set.(:turnstile)

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert conn.request_path == "/turnstile/v0/siteverify"
        assert params == %{"secret" => "secret", "response" => "tok", "remoteip" => "203.0.113.9"}
        Req.Test.json(conn, %{"success" => params["response"] == "tok"})
      end)

      assert :ok = Captcha.verify(%{"cf-turnstile-response" => "tok"}, @ip)
      assert {:error, :missing} = Captcha.verify(%{}, @ip)
    end

    test "Friendly Captcha v2 uses the X-API-Key header", %{set: set} do
      set.(:friendly_captcha)

      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["secret"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"response" => "r", "sitekey" => "site"} = Jason.decode!(body)

        Req.Test.json(conn, %{
          "success" => false,
          "error" => %{"error_code" => "response_duplicate"}
        })
      end)

      assert {:error, :rejected} = Captcha.verify(%{"frc-captcha-response" => "r"}, @ip)
    end

    test "Captcha.eu posts the solution unchanged with the Rest-Key header", %{set: set} do
      set.(:captcha_eu)

      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "rest-key") == ["secret"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == ~s({"a":1})
        Req.Test.json(conn, %{"success" => true})
      end)

      assert :ok = Captcha.verify(%{"captcha_at_solution" => ~s({"a":1})}, @ip)
    end

    test "an outage lets the attempt through; a rejected key does not", %{set: set} do
      set.(:turnstile)
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 503, "down"))
      assert :ok = Captcha.verify(%{"cf-turnstile-response" => "tok"}, @ip)

      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
      assert :ok = Captcha.verify(%{"cf-turnstile-response" => "tok"}, @ip)

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 401, "bad key"))
      assert {:error, :misconfigured} = Captcha.verify(%{"cf-turnstile-response" => "tok"}, @ip)
    end
  end
end
