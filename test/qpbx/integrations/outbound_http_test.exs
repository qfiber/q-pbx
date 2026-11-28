defmodule QPBX.Integrations.OutboundHTTPTest do
  use ExUnit.Case, async: true
  alias QPBX.Integrations
  alias QPBX.Integrations.Address

  defmodule Receiver do
    @moduledoc false
    # A local test server: echoes what it got, redirects, sends a large or a slow answer.
    use Plug.Router
    plug :match
    plug :dispatch

    get("/big", do: send_resp(conn, 200, :binary.copy("x", 2_000_000)))
    get("/slow", do: Process.sleep(1_500) && send_resp(conn, 200, "late"))

    match "/redirect" do
      conn = Plug.Conn.fetch_query_params(conn)

      conn
      |> put_resp_header("location", conn.query_params["to"])
      |> send_resp(String.to_integer(conn.query_params["status"] || "302"), "")
    end

    match("/loop", do: conn |> put_resp_header("location", "/loop") |> send_resp(302, ""))

    match _ do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send_resp(
        conn,
        200,
        Jason.encode!(%{
          method: conn.method,
          path: conn.request_path,
          host: Plug.Conn.get_req_header(conn, "host") |> List.first(),
          auth: Plug.Conn.get_req_header(conn, "authorization") |> List.first(),
          body: body
        })
      )
    end
  end

  # Local servers are "inside": tests allow only 127.0.0.1 explicitly, as an operator would.
  @local [allow_http: true, allow_cidrs: ["127.0.0.1"]]

  setup do
    {:ok, pid} =
      start_supervised({Bandit, plug: Receiver, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    %{port: port, base: "http://127.0.0.1:#{port}"}
  end

  defp echo({:ok, %{status: 200, body: body}}), do: Jason.decode!(body)

  describe "addresses" do
    test "only public addresses; every inside form is refused" do
      for ip <- ~w(8.8.8.8 1.1.1.1 2606:4700::1111 2a00:1450:4001::200e),
          do: assert(Address.public?(parse(ip)), ip)

      inside =
        ~w(127.0.0.1 10.1.2.3 172.16.0.1 172.31.255.255 192.168.10.25 169.254.169.254 100.64.0.1
                  0.0.0.0 224.0.0.1 255.255.255.255 198.51.100.7 ::1 :: ::ffff:127.0.0.1 ::ffff:10.0.0.1
                  ::127.0.0.1 64:ff9b::7f00:1 64:ff9b:1::a00:1 2002:7f00:1::1 2001:0:4136:e378::1
                  fd00::1 fe80::1 fec0::1 ff02::1 2001:db8::1)

      for ip <- inside, do: refute(Address.public?(parse(ip)), ip)
      assert Address.allowed?(parse("192.168.10.236"), ["192.168.10.0/24"])

      refute Address.allowed?(parse("192.168.11.1"), [
               "192.168.10.0/24",
               "not-a-cidr",
               "10.0.0.0/99"
             ])
    end
  end

  describe "refusals" do
    test "plain HTTP needs the installation's permission; no credentials in the URL", %{
      base: base
    } do
      assert {:error, :https_required} =
               Integrations.request(:get, base <> "/x", allow_cidrs: ["127.0.0.1"])

      assert {:error, :bad_url} = Integrations.request(:get, "https://user:pw@example.com/")
      assert {:error, :bad_url} = Integrations.request(:get, "ftp://example.com/")
      assert {:error, :bad_url} = Integrations.request(:get, "not a url")
    end

    test "inside addresses in every spelling, without an allowance", %{port: port} do
      for host <- [
            "127.0.0.1",
            "2130706433",
            "0x7f.1",
            "127.1",
            "[::1]",
            "[::ffff:127.0.0.1]",
            "[::ffff:7f00:1]",
            "localhost",
            "169.254.169.254"
          ] do
        assert {:error, {:blocked_address, _}} =
                 Integrations.request(:get, "http://#{host}:#{port}/x", allow_http: true),
               host
      end
    end

    test "a name with one inside answer among public ones is refused (DNS rebinding)", %{
      port: port
    } do
      resolver = fn "mixed.example" -> [{93, 184, 216, 34}, {10, 0, 0, 5}] end

      assert {:error, {:blocked_address, "10.0.0.5"}} =
               Integrations.request(:get, "http://mixed.example:#{port}/",
                 allow_http: true,
                 resolver: resolver
               )
    end

    test "every redirect is checked again", %{base: base} do
      to = URI.encode_www_form("http://169.254.169.254/latest/meta-data")

      assert {:error, {:blocked_address, "169.254.169.254"}} =
               Integrations.request(:get, "#{base}/redirect?to=#{to}", @local)

      to = URI.encode_www_form("http://[::ffff:10.0.0.1]/")

      assert {:error, {:blocked_address, _}} =
               Integrations.request(:get, "#{base}/redirect?to=#{to}", @local)

      assert {:error, :too_many_redirects} = Integrations.request(:get, base <> "/loop", @local)
    end
  end

  describe "allowed requests" do
    test "a request reaches the server with its body and headers", %{base: base} do
      res =
        Integrations.request(
          :post,
          base <> "/hook?a=1",
          @local ++ [body: ~s({"x":1}), headers: [{"content-type", "application/json"}]]
        )

      assert %{"method" => "POST", "path" => "/hook", "body" => ~s({"x":1})} = echo(res)
    end

    test "the connection goes to the checked address, the name stays in Host", %{port: port} do
      resolver = fn "hooks.example" -> [{127, 0, 0, 1}] end

      res =
        Integrations.request(
          :get,
          "http://hooks.example:#{port}/x",
          @local ++ [resolver: resolver]
        )

      assert %{"host" => "hooks.example:" <> _} = echo(res)
    end

    test "redirects: followed within the limit; 303 becomes GET; authorization dropped on another host",
         %{base: base, port: port} do
      to = URI.encode_www_form("/after")

      assert %{"method" => "GET", "path" => "/after", "body" => ""} =
               echo(
                 Integrations.request(
                   :post,
                   "#{base}/redirect?status=303&to=#{to}",
                   @local ++ [body: "x"]
                 )
               )

      assert %{"method" => "POST", "body" => "x"} =
               echo(
                 Integrations.request(
                   :post,
                   "#{base}/redirect?status=307&to=#{to}",
                   @local ++ [body: "x"]
                 )
               )

      other = URI.encode_www_form("http://other.example:#{port}/after")
      resolver = fn "other.example" -> [{127, 0, 0, 1}] end
      opts = @local ++ [resolver: resolver, headers: [{"authorization", "Bearer secret"}]]

      assert %{"auth" => nil, "host" => "other.example:" <> _} =
               echo(Integrations.request(:get, "#{base}/redirect?to=#{other}", opts))

      assert %{"auth" => "Bearer secret"} =
               echo(Integrations.request(:get, "#{base}/redirect?to=#{to}", opts))
    end

    test "size and time limits", %{base: base} do
      assert {:error, :too_large} = Integrations.request(:get, base <> "/big", @local)

      assert {:ok, %{body: body}} =
               Integrations.request(:get, base <> "/big", @local ++ [max_body: 3_000_000])

      assert byte_size(body) == 2_000_000

      assert {:error, :timeout} =
               Integrations.request(:get, base <> "/slow", @local ++ [timeout: 300])
    end
  end

  describe "HTTPS" do
    setup do
      k = [key: {:namedCurve, :secp256r1}, digest: :sha256]
      san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"hooks.example"]}

      data =
        :public_key.pkix_test_data(%{
          server_chain: %{root: k, intermediates: [], peer: k ++ [extensions: [san]]},
          client_chain: %{root: k, intermediates: [], peer: k}
        })

      {:ok, pid} =
        start_supervised(
          {Bandit,
           plug: Receiver,
           scheme: :https,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           thousand_island_options: [transport_options: data.server_config]},
          id: :tls
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(pid)
      %{tls_port: port, cacerts: data.client_config[:cacerts]}
    end

    test "the certificate is verified for the name while connecting to the checked address", %{
      tls_port: port,
      cacerts: cacerts
    } do
      opts = [allow_cidrs: ["127.0.0.1"], cacerts: cacerts]
      ok = fn _ -> [{127, 0, 0, 1}] end

      assert %{"host" => "hooks.example:" <> _} =
               echo(
                 Integrations.request(
                   :get,
                   "https://hooks.example:#{port}/x",
                   opts ++ [resolver: ok]
                 )
               )

      # Another name at the same address: its certificate does not match, refused.
      assert {:error, {:connect, _}} =
               Integrations.request(
                 :get,
                 "https://wrong.example:#{port}/x",
                 opts ++ [resolver: ok]
               )

      # A redirect from HTTPS to plain HTTP is refused like any plain HTTP address.
      to = URI.encode_www_form("http://hooks.example:#{port}/x")

      assert {:error, :https_required} =
               Integrations.request(
                 :get,
                 "https://hooks.example:#{port}/redirect?to=#{to}",
                 opts ++ [resolver: ok]
               )

      # A certificate from an unknown authority: refused.
      assert {:error, {:connect, _}} =
               Integrations.request(:get, "https://hooks.example:#{port}/x",
                 allow_cidrs: ["127.0.0.1"],
                 resolver: ok
               )
    end
  end

  defp parse(ip), do: ip |> String.to_charlist() |> :inet.parse_address() |> elem(1)
end
