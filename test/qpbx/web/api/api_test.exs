defmodule QPBX.Web.ApiTest do
  use QPBX.Web.ConnCase, async: true
  import Ecto.Query, only: [from: 2]
  import QPBX.Fixtures
  alias QPBX.Core

  @actor {:system, "test"}

  defp key(scope, scopes, attrs \\ %{}) do
    {:ok, key, token} =
      Core.create_api_key(scope, Map.merge(%{name: "k", scopes: scopes}, attrs), @actor)

    {key, token}
  end

  defp with_key(conn, token),
    do:
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json")

  setup do
    t = tenant_fixture()
    scope = Core.scope_for(user_fixture(t))
    {:ok, e101} = Core.create_extension(scope, %{number: "101", name: "Dana"}, @actor)
    {_, token} = key(scope, ~w(read write))
    %{t: t, scope: scope, e101: e101, token: token}
  end

  describe "keys" do
    test "no key, a wrong key and an expired key get 401 in the error format", %{
      conn: conn,
      scope: scope
    } do
      assert %{"error" => %{"code" => "unauthorized"}} =
               conn |> get(~p"/v1/me") |> json_response(401)

      assert %{"error" => %{"code" => "unauthorized"}} =
               conn |> with_key("qpbx_wrong") |> get(~p"/v1/me") |> json_response(401)

      {key, token} = key(scope, ["read"])

      QPBX.Repo.update_all(
        from(k in Core.ApiKey, where: k.id == ^key.id),
        set: [expires_at: ~U[2020-01-01 00:00:00Z]]
      )

      assert %{"error" => %{"code" => "key_expired"}} =
               conn |> with_key(token) |> get(~p"/v1/me") |> json_response(401)
    end

    test "a revoked key stops at once", %{conn: conn, scope: scope} do
      {key, token} = key(scope, ["read"])
      assert conn |> with_key(token) |> get(~p"/v1/me") |> json_response(200)
      {:ok, _} = Core.revoke_api_key(scope, key.id, @actor)
      assert conn |> with_key(token) |> get(~p"/v1/me") |> json_response(401)
    end

    test "/v1/me describes the key, never its secret", %{conn: conn, token: token, t: t} do
      body = conn |> with_key(token) |> get(~p"/v1/me") |> json_response(200)

      assert %{"data" => %{"kind" => "tenant", "scopes" => ["read", "write"], "tenant_id" => tid}} =
               body

      assert tid == t.id
      refute inspect(body) =~ token
    end
  end

  describe "scopes and audience" do
    test "a read-only key cannot write", %{conn: conn, scope: scope} do
      {_, token} = key(scope, ["read"])

      assert %{
               "error" => %{
                 "code" => "missing_scope",
                 "details" => %{"required_scope" => "write"}
               }
             } =
               conn
               |> with_key(token)
               |> post(~p"/v1/extensions", %{number: "150", name: "X"})
               |> json_response(403)

      assert Enum.map(Core.list_extensions(scope), & &1.number) == ["101"]
    end

    test "a key without read cannot list", %{conn: conn, scope: scope} do
      {_, token} = key(scope, ["calls"])
      assert conn |> with_key(token) |> get(~p"/v1/extensions") |> json_response(403)
    end

    test "tenant keys cannot use platform endpoints and the reverse", %{conn: conn, token: token} do
      assert %{"error" => %{"code" => "wrong_key_kind"}} =
               conn |> with_key(token) |> get(~p"/v1/tenants") |> json_response(403)

      {_, plat} = key(Core.scope_for(platform_admin_fixture()), ["read"])

      assert %{"error" => %{"code" => "wrong_key_kind"}} =
               conn |> with_key(plat) |> get(~p"/v1/extensions") |> json_response(403)

      assert %{"data" => tenants} =
               conn |> with_key(plat) |> get(~p"/v1/tenants") |> json_response(200)

      assert tenants != []
    end
  end

  describe "tenant isolation" do
    test "another tenant's key gets nothing of this tenant", %{conn: conn, e101: e101} do
      other = Core.scope_for(user_fixture(tenant_fixture()))
      {:ok, _} = Core.create_extension(other, %{number: "101", name: "Other"}, @actor)
      {_, theirs} = key(other, ["read"])

      assert %{"data" => [%{"name" => "Other"}]} =
               conn |> with_key(theirs) |> get(~p"/v1/extensions") |> json_response(200)

      # Raised as not found and rendered by ErrorJSON in the API's format.
      {404, _, body} =
        assert_error_sent(404, fn ->
          conn |> with_key(theirs) |> get(~p"/v1/extensions/#{e101.id}")
        end)

      assert %{"error" => %{"code" => "not_found"}} = Jason.decode!(body)
    end

    test "a malformed id is a 400, not a crash", %{conn: conn, token: token} do
      {400, _, body} =
        assert_error_sent(400, fn -> conn |> with_key(token) |> get(~p"/v1/extensions/nope") end)

      assert %{"error" => %{"code" => "bad_request"}} = Jason.decode!(body)
    end
  end

  describe "lists, writes and errors" do
    test "cursor pagination walks every item once", %{conn: conn, scope: scope, token: token} do
      for n <- 102..105,
          do: {:ok, _} = Core.create_extension(scope, %{number: "#{n}", name: "E#{n}"}, @actor)

      {numbers, pages} =
        Stream.unfold({nil, 0}, fn
          :done ->
            nil

          {cursor, _} ->
            params = if cursor, do: %{limit: 2, cursor: cursor}, else: %{limit: 2}

            body =
              conn |> with_key(token) |> get(~p"/v1/extensions", params) |> json_response(200)

            numbers = Enum.map(body["data"], & &1["number"])
            {numbers, if(body["next_cursor"], do: {body["next_cursor"], 0}, else: :done)}
        end)
        |> Enum.to_list()
        |> then(&{List.flatten(&1), length(&1)})

      assert Enum.sort(numbers) == ~w(101 102 103 104 105)
      assert pages == 3

      assert %{"error" => %{"code" => "bad_request"}} =
               conn
               |> with_key(token)
               |> get(~p"/v1/extensions", %{cursor: "!!"})
               |> json_response(400)

      assert conn |> with_key(token) |> get(~p"/v1/extensions", %{limit: 0}) |> json_response(400)
    end

    test "create returns 201; invalid fields come back per field", %{
      conn: conn,
      scope: scope,
      token: token
    } do
      assert %{"data" => %{"number" => "150", "devices" => []}} =
               conn
               |> with_key(token)
               |> post(~p"/v1/extensions", %{number: "150", name: "New"})
               |> json_response(201)

      assert %{"error" => %{"code" => "invalid", "details" => %{"number" => [_]}}} =
               conn
               |> with_key(token)
               |> post(~p"/v1/extensions", %{number: "0", name: "Bad"})
               |> json_response(422)

      # The audit log names the key as the actor.
      [entry | _] = Core.list_my_audit_logs(scope)
      assert entry.actor_type == "api_key"
    end

    test "an idempotent POST runs once; reusing the key for another body is refused",
         %{conn: conn, scope: scope, token: token} do
      send = fn body ->
        conn
        |> with_key(token)
        |> put_req_header("idempotency-key", "abc-1")
        |> post(~p"/v1/extensions", body)
      end

      first = send.(%{number: "160", name: "Once"})
      again = send.(%{number: "160", name: "Once"})
      assert json_response(first, 201) == json_response(again, 201)
      assert get_resp_header(again, "idempotent-replayed") == ["true"]
      assert Enum.count(Core.list_extensions(scope), &(&1.number == "160")) == 1

      assert %{"error" => %{"code" => "idempotency_key_reused"}} =
               send.(%{number: "161", name: "Other"}) |> json_response(422)
    end

    test "the plan's rate limit answers 429 with retry-after", %{conn: conn} do
      t = tenant_fixture(plan_id: plan_fixture(%{api_rate_limit_per_minute: 2}).id)
      {_, token} = key(Core.scope_for(user_fixture(t)), ["read"])
      first = conn |> with_key(token) |> get(~p"/v1/me")
      assert get_resp_header(first, "x-ratelimit-limit") == ["2"]
      assert get_resp_header(first, "x-ratelimit-remaining") == ["1"]
      assert conn |> with_key(token) |> get(~p"/v1/me") |> json_response(200)
      limited = conn |> with_key(token) |> get(~p"/v1/me")
      assert %{"error" => %{"code" => "rate_limited"}} = json_response(limited, 429)
      assert [secs] = get_resp_header(limited, "retry-after")
      assert String.to_integer(secs) in 1..60
    end
  end

  describe "OpenAPI document and explorer" do
    test "every /v1 route is documented with its scope", %{conn: conn} do
      doc = conn |> get(~p"/v1/openapi.json") |> json_response(200)
      assert doc["openapi"] == "3.1.0"

      for %{path: "/v1/" <> _ = path, verb: verb, plug: plug} <-
            Phoenix.Router.routes(QPBX.Web.Router),
          plug != QPBX.Web.Api.SpecController do
        oa = Regex.replace(~r/:(\w+)/, path, "{\\1}")
        op = doc["paths"][oa][to_string(verb)]
        assert op, "#{verb} #{path} is not in the document"
        assert op["x-scope"] in Core.ApiKey.scopes()
      end

      assert doc["paths"]["/v1/extensions"]["post"]["requestBody"]
      assert doc["components"]["schemas"]["Extension"]
    end

    test "the explorer is served by the app under the portal's CSP", %{conn: conn} do
      conn = get(conn, ~p"/v1/docs")
      html = html_response(conn, 200)
      assert html =~ ~s(src="/assets/js/api_explorer.js")
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src 'self'"
      refute html =~ "https://"
    end
  end
end
