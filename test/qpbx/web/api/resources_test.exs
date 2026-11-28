defmodule QPBX.Web.Api.ResourcesTest do
  @moduledoc "A request for every /v1 resource and action, through the same Core functions the portal uses."
  use QPBX.Web.ConnCase, async: false
  use Oban.Testing, repo: QPBX.Repo
  import QPBX.Fixtures
  alias QPBX.{Core, Telephony}

  @actor {:system, "test"}
  @mp3 <<"ID3", 4, 0, 0, 0, 0, 0, 0>> <> :binary.copy(<<9>>, 64)

  defp key(scope, scopes) do
    {:ok, _, token} = Core.create_api_key(scope, %{name: "k", scopes: scopes}, @actor)
    token
  end

  # {status, decoded body (nil when empty)}
  defp api(token, method, path, body \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json")

    conn =
      case body do
        {:raw, type, bin} ->
          conn |> put_req_header("content-type", type) |> dispatch(@endpoint, method, path, bin)

        nil ->
          dispatch(conn, @endpoint, method, path)

        map ->
          conn
          |> put_req_header("content-type", "application/json")
          |> dispatch(@endpoint, method, path, Jason.encode!(map))
      end

    {conn.status, if(conn.resp_body in ["", nil], do: nil, else: Jason.decode!(conn.resp_body))}
  end

  setup do
    plat = Core.scope_for(platform_admin_fixture())
    t = tenant_fixture()
    scope = Core.scope_for(user_fixture(t))

    %{
      t: t,
      scope: scope,
      ptok: key(plat, ~w(read write admin)),
      tok: key(scope, ~w(read write admin)),
      plat: plat
    }
  end

  describe "platform" do
    test "tenants: list, create with admin, get, change; users, admin, setup link, sign out", %{
      ptok: k,
      t: t
    } do
      plan = plan_fixture()
      assert {200, %{"data" => [_ | _]}} = api(k, :get, "/v1/tenants")

      body = %{
        name: "New Co",
        slug: "newco#{unique()}",
        timezone: "Asia/Jerusalem",
        locale: "ar",
        plan_id: plan.id,
        admin: %{name: "Boss", email: "boss#{unique()}@x.test"}
      }

      assert {201, %{"data" => %{"id" => id, "locale" => "ar"}}} =
               api(k, :post, "/v1/tenants", body)

      assert_enqueued(worker: QPBX.Notify.SetupLinkEmail)

      assert {422, %{"error" => %{"details" => %{"admin" => %{"email" => _}}}}} =
               api(k, :post, "/v1/tenants", %{
                 body
                 | slug: "x#{unique()}",
                   admin: %{name: "A", email: "nope"}
               })

      assert {200, %{"data" => %{"name" => "New Co"}}} = api(k, :get, "/v1/tenants/#{id}")

      assert {200, %{"data" => %{"name" => "Renamed"}}} =
               api(k, :patch, "/v1/tenants/#{id}", %{name: "Renamed"})

      assert {200, %{"data" => [%{"role" => "tenant_admin", "email" => _} = u]}} =
               api(k, :get, "/v1/tenants/#{id}/users")

      refute Map.has_key?(u, "hashed_password")

      assert {201, %{"data" => %{"role" => "tenant_admin"}}} =
               api(k, :post, "/v1/tenants/#{id}/users", %{
                 name: "Two",
                 email: "two#{unique()}@x.test"
               })

      assert {204, nil} = api(k, :post, "/v1/tenants/#{id}/users/#{u["id"]}/setup-link")
      assert {204, nil} = api(k, :post, "/v1/tenants/#{id}/users/#{u["id"]}/sign-out")
      assert {404, _} = api(k, :post, "/v1/tenants/#{t.id}/users/#{u["id"]}/sign-out")
    end

    test "plans: list, create, get, change", %{ptok: k} do
      assert {201, %{"data" => %{"id" => id}}} =
               api(k, :post, "/v1/plans", %{name: "Gold#{unique()}", max_extensions: 5})

      assert {200, %{"data" => %{"max_extensions" => 5}}} = api(k, :get, "/v1/plans/#{id}")

      assert {200, %{"data" => %{"max_extensions" => 9}}} =
               api(k, :patch, "/v1/plans/#{id}", %{max_extensions: 9})

      assert {200, %{"data" => plans}} = api(k, :get, "/v1/plans?limit=200")
      assert Enum.any?(plans, &(&1["id"] == id))
    end

    test "trunks: create, get, list, change, delete; no password back", %{ptok: k} do
      body = %{
        name: "Carrier",
        auth_mode: "registration",
        username: "u",
        password: "secret-pw",
        addresses: [%{host: "sip.example.net"}]
      }

      assert {201, %{"data" => %{"id" => id} = trunk}} = api(k, :post, "/v1/trunks", body)
      refute inspect(trunk) =~ "secret-pw"
      assert [%{"host" => "sip.example.net"}] = trunk["addresses"]
      assert {200, %{"data" => %{"name" => "Carrier"}}} = api(k, :get, "/v1/trunks/#{id}")
      assert {200, %{"data" => [_]}} = api(k, :get, "/v1/trunks")

      assert {200, %{"data" => %{"max_channels" => 30}}} =
               api(k, :patch, "/v1/trunks/#{id}", %{max_channels: 30})

      assert {204, nil} = api(k, :delete, "/v1/trunks/#{id}")
    end

    test "numbers: add, assign, change, remove; a tenant points its own", %{
      ptok: k,
      tok: tk,
      t: t,
      scope: scope
    } do
      {:ok, trunk} =
        Core.create_trunk(
          %Core.Scope{kind: :platform},
          %{name: "T", auth_mode: "ip", addresses: [%{host: "203.0.113.9"}]},
          @actor
        )

      assert {201, %{"data" => %{"id" => id}}} =
               api(k, :post, "/v1/numbers", %{number: "+97221234567", trunk_id: trunk.id})

      assert {422, _} = api(k, :post, "/v1/numbers", %{number: "02-123", trunk_id: trunk.id})

      assert {200, %{"data" => %{"tenant_id" => tid}}} =
               api(k, :patch, "/v1/numbers/#{id}", %{tenant_id: t.id})

      assert tid == t.id
      assert {200, %{"data" => [_]}} = api(k, :get, "/v1/numbers")

      {:ok, ext} = Core.create_extension(scope, %{number: "101", name: "A"}, @actor)
      assert {200, %{"data" => [%{"id" => ^id}]}} = api(tk, :get, "/v1/numbers")

      assert {200, %{"data" => %{"destination_id" => eid}}} =
               api(tk, :put, "/v1/numbers/#{id}/destination", %{
                 destination_type: "extension",
                 destination_id: ext.id
               })

      assert eid == ext.id
      assert {200, _} = api(tk, :get, "/v1/numbers/#{id}")
      assert {403, _} = api(tk, :delete, "/v1/numbers/#{id}")
      assert {204, nil} = api(k, :delete, "/v1/numbers/#{id}")
    end

    test "number classes, emergency routes, number format", %{ptok: k, tok: tk} do
      {:ok, trunk} =
        Core.create_trunk(
          %Core.Scope{kind: :platform},
          %{name: "T", auth_mode: "ip", addresses: [%{host: "203.0.113.8"}]},
          @actor
        )

      assert {201, %{"data" => %{"id" => cid}}} =
               api(k, :post, "/v1/number-classes", %{prefix: "+9725", class: "mobile"})

      assert {200, %{"data" => [_ | _]}} = api(k, :get, "/v1/number-classes")
      assert {204, nil} = api(k, :delete, "/v1/number-classes/#{cid}")

      assert {201, %{"data" => %{"id" => eid}}} =
               api(k, :post, "/v1/emergency-routes", %{number: "100", trunk_id: trunk.id})

      assert {200, %{"data" => [_]}} = api(k, :get, "/v1/emergency-routes")
      assert {204, nil} = api(k, :delete, "/v1/emergency-routes/#{eid}")

      assert {200, %{"data" => %{"country_code" => "972", "area_code" => "3"}}} =
               api(k, :put, "/v1/number-format", %{country_code: "972", area_code: "3"})

      assert {200, %{"data" => %{"area_code" => "4"}}} =
               api(tk, :put, "/v1/number-format", %{country_code: "972", area_code: "4"})

      assert {200, %{"data" => %{"area_code" => "4"}}} = api(tk, :get, "/v1/number-format")
      assert {204, nil} = api(tk, :delete, "/v1/number-format")
      assert {200, %{"data" => %{"area_code" => "3"}}} = api(tk, :get, "/v1/number-format")
      assert {403, _} = api(k, :delete, "/v1/number-format")
    end

    test "firewall, protection, fraud", %{ptok: k} do
      assert {201, %{"data" => %{"id" => id}}} =
               api(k, :post, "/v1/firewall", %{
                 kind: "block",
                 scope: "all",
                 cidr: "198.51.100.7",
                 reason: "abuse"
               })

      assert {200, %{"data" => entries}} = api(k, :get, "/v1/firewall")
      assert Enum.any?(entries, &(&1["id"] == id))
      assert {204, nil} = api(k, :delete, "/v1/firewall/#{id}")

      assert {200, %{"data" => %{"ban_seconds" => _}}} = api(k, :get, "/v1/protection")

      assert {200, %{"data" => %{"ban_seconds" => 900}}} =
               api(k, :patch, "/v1/protection", %{ban_seconds: 900})

      assert {200, %{"data" => _, "next_cursor" => nil}} = api(k, :get, "/v1/protection/bans")
      assert {204, nil} = api(k, :delete, "/v1/protection/bans/198.51.100.8")

      assert {200, %{"data" => %{"block_hours" => _}}} = api(k, :get, "/v1/fraud")

      assert {200, %{"data" => %{"block_hours" => 6}}} =
               api(k, :patch, "/v1/fraud", %{block_hours: 6})

      assert {200, %{"data" => []}} = api(k, :get, "/v1/fraud/blocks")
      # Lifting is idempotent: an unknown or already lifted block is fine.
      assert {204, nil} = api(k, :delete, "/v1/fraud/blocks/#{Ecto.UUID.generate()}")
    end

    test "platform admins: list, add, setup link, sign out; needs the admin scope", %{
      ptok: k,
      plat: plat
    } do
      assert {201, %{"data" => %{"id" => id}}} =
               api(k, :post, "/v1/platform-admins", %{name: "Ops", email: "ops#{unique()}@x.test"})

      assert {200, %{"data" => admins}} = api(k, :get, "/v1/platform-admins?limit=200")
      assert Enum.any?(admins, &(&1["id"] == id))
      refute Enum.any?(admins, &Map.has_key?(&1, "totp_secret"))
      assert {204, nil} = api(k, :post, "/v1/platform-admins/#{id}/setup-link")
      assert {204, nil} = api(k, :post, "/v1/platform-admins/#{id}/sign-out")
      assert {404, _} = api(k, :post, "/v1/platform-admins/#{Ecto.UUID.generate()}/sign-out")
      assert {403, _} = api(key(plat, ~w(read write)), :get, "/v1/platform-admins")
    end

    test "audit log pages by cursor; a tenant key sees only its own", %{
      ptok: k,
      tok: tk,
      t: t,
      scope: scope
    } do
      for n <- 1..3,
          do: {:ok, _} = Core.create_extension(scope, %{number: "#{200 + n}", name: "E"}, @actor)

      assert {200, %{"data" => [_, _], "next_cursor" => c}} =
               api(k, :get, "/v1/audit?limit=2&tenant_id=#{t.id}")

      assert {200, %{"data" => more}} =
               api(k, :get, "/v1/audit?limit=200&tenant_id=#{t.id}&cursor=#{c}")

      assert length(more) >= 2

      assert {200, %{"data" => mine}} = api(tk, :get, "/v1/audit?limit=200")
      assert Enum.all?(mine, &(&1["tenant_id"] == t.id))
    end

    test "API keys through the API; the token comes back once", %{tok: tk, scope: scope} do
      assert {201, %{"data" => %{"id" => id}, "token" => "qpbx_" <> _ = token}} =
               api(tk, :post, "/v1/api-keys", %{name: "CI", scopes: ["read"]})

      assert {200, _} = api(token, :get, "/v1/me")
      assert {200, %{"data" => keys}} = api(tk, :get, "/v1/api-keys")
      refute inspect(keys) =~ token
      assert {204, nil} = api(tk, :delete, "/v1/api-keys/#{id}")
      assert {401, _} = api(token, :get, "/v1/me")
      assert {403, _} = api(key(scope, ~w(read write)), :get, "/v1/api-keys")
    end
  end

  describe "tenant" do
    test "extensions: create, change, delete; devices with a password shown once", %{tok: k} do
      assert {201, %{"data" => %{"id" => id}}} =
               api(k, :post, "/v1/extensions", %{number: "101", name: "Dana"})

      assert {200, %{"data" => %{"dnd" => true, "forward_busy" => "+97221234567"}}} =
               api(k, :patch, "/v1/extensions/#{id}", %{dnd: true, forward_busy: "+97221234567"})

      assert {201, %{"data" => %{"id" => did, "sip_username" => "101"}, "sip_password" => pw}} =
               api(k, :post, "/v1/extensions/#{id}/devices", %{label: "", kind: "softphone"})

      assert byte_size(pw) >= 16
      assert {200, %{"data" => %{"devices" => [dev]}}} = api(k, :get, "/v1/extensions/#{id}")
      refute inspect(dev) =~ pw
      assert {200, %{"sip_password" => pw2}} = api(k, :post, "/v1/devices/#{did}/reset-password")
      assert pw2 != pw
      assert {204, nil} = api(k, :delete, "/v1/devices/#{did}")
      assert {204, nil} = api(k, :delete, "/v1/extensions/#{id}")
      assert {200, %{"data" => []}} = api(k, :get, "/v1/extensions")
    end

    test "voicemail: mailbox, greetings, messages, short-lived audio link", %{
      tok: k,
      scope: scope,
      t: t
    } do
      {:ok, ext} = Core.create_extension(scope, %{number: "101", name: "Dana"}, @actor)

      assert {200, %{"data" => %{"enabled" => true}}} =
               api(k, :get, "/v1/extensions/#{ext.id}/mailbox")

      assert {200, %{"data" => mb}} =
               api(k, :put, "/v1/extensions/#{ext.id}/mailbox", %{pin: "4831", email: "d@x.test"})

      refute Map.has_key?(mb, "pin_hash")

      assert {204, nil} =
               api(
                 k,
                 :put,
                 "/v1/extensions/#{ext.id}/greetings/unavailable",
                 {:raw, "audio/mpeg", @mp3}
               )

      assert {422, %{"error" => %{"code" => "not_audio"}}} =
               api(
                 k,
                 :put,
                 "/v1/extensions/#{ext.id}/greetings/unavailable",
                 {:raw, "audio/mpeg", "text"}
               )

      assert {200, %{"data" => ["unavailable"]}} =
               api(k, :get, "/v1/extensions/#{ext.id}/greetings")

      assert {204, nil} = api(k, :delete, "/v1/extensions/#{ext.id}/greetings/unavailable")

      mb = Telephony.mailbox(scope, ext.id)

      {:ok, msg} =
        Telephony.Voicemail.store_system(mb, @mp3, %{
          caller_number: "+97250",
          caller_name: "X",
          duration: 3,
          format: "mp3"
        })

      assert {200, %{"data" => [%{"id" => id, "extension_id" => eid, "folder" => "new"} = m]}} =
               api(k, :get, "/v1/voicemails?extension_id=#{ext.id}")

      assert id == msg.id and eid == ext.id
      refute Map.has_key?(m, "file_key")

      assert {200, %{"url" => url}} = api(k, :post, "/v1/voicemails/#{id}/audio-link")
      path = URI.parse(url).path
      audio = get(build_conn(), path)
      assert audio.status == 200 and audio.resp_body == @mp3
      assert get(build_conn(), path <> "x").status == 404

      assert {204, nil} = api(k, :post, "/v1/voicemails/#{id}/save")
      assert {200, %{"data" => [%{"folder" => "saved"}]}} = api(k, :get, "/v1/voicemails")
      assert {204, nil} = api(k, :delete, "/v1/voicemails/#{id}")
      assert {404, _} = api(k, :delete, "/v1/voicemails/#{id}")
      assert {204, nil} = api(k, :delete, "/v1/extensions/#{ext.id}/mailbox")
      _ = t
    end

    test "users: invite, role, extension, setup link, sign out, remove", %{tok: k, scope: scope} do
      {:ok, ext} = Core.create_extension(scope, %{number: "101", name: "Dana"}, @actor)

      assert {201, %{"data" => %{"id" => id, "role" => "tenant_user", "extension_id" => eid}}} =
               api(k, :post, "/v1/users", %{
                 name: "Dana",
                 email: "dana#{unique()}@x.test",
                 extension_id: ext.id
               })

      assert eid == ext.id

      assert {200, %{"data" => %{"role" => "tenant_admin", "extension_id" => nil}}} =
               api(k, :patch, "/v1/users/#{id}", %{role: "tenant_admin", extension_id: nil})

      assert {422, %{"error" => %{"code" => "unknown_role"}}} =
               api(k, :patch, "/v1/users/#{id}", %{role: "root"})

      assert {422, %{"error" => %{"code" => "no_such_extension"}}} =
               api(k, :patch, "/v1/users/#{id}", %{extension_id: Ecto.UUID.generate()})

      assert {204, nil} = api(k, :post, "/v1/users/#{id}/setup-link")
      assert {204, nil} = api(k, :post, "/v1/users/#{id}/sign-out")
      assert {200, %{"data" => [_, _]}} = api(k, :get, "/v1/users")
      assert {204, nil} = api(k, :delete, "/v1/users/#{id}")
    end

    test "routes: create, get, list, change, delete", %{tok: k} do
      {:ok, trunk} =
        Core.create_trunk(
          %Core.Scope{kind: :platform},
          %{name: "T", auth_mode: "ip", addresses: [%{host: "203.0.113.7"}]},
          @actor
        )

      body = %{name: "IL", prefixes: ["+972"], destination_class: "local", trunk_ids: [trunk.id]}

      assert {201, %{"data" => %{"id" => id, "trunk_ids" => [tid]}}} =
               api(k, :post, "/v1/routes", body)

      assert tid == trunk.id
      assert {200, %{"data" => %{"name" => "IL"}}} = api(k, :get, "/v1/routes/#{id}")

      assert {200, %{"data" => %{"strip_digits" => 1}}} =
               api(k, :patch, "/v1/routes/#{id}", %{strip_digits: 1})

      assert {200, %{"data" => [_]}} = api(k, :get, "/v1/routes")
      assert {204, nil} = api(k, :delete, "/v1/routes/#{id}")
    end

    test "office IPs: add, list, remove; another tenant's is not found", %{tok: k} do
      assert {201, %{"data" => %{"id" => id, "scope" => "sip", "kind" => "allow"}}} =
               api(k, :post, "/v1/office-ips", %{
                 cidr: "198.51.100.20",
                 reason: "HQ",
                 kind: "block"
               })

      assert {200, %{"data" => [_]}} = api(k, :get, "/v1/office-ips")
      other = key(Core.scope_for(user_fixture(tenant_fixture())), ~w(read write))
      assert {404, _} = api(other, :delete, "/v1/office-ips/#{id}")
      assert {204, nil} = api(k, :delete, "/v1/office-ips/#{id}")
    end

    test "webhooks: add (secret once), change, rotate, deliveries, resend, remove", %{
      tok: k,
      t: t,
      scope: scope
    } do
      old = Application.get_env(:qpbx, QPBX.Integrations)
      Application.put_env(:qpbx, QPBX.Integrations, [])
      on_exit(fn -> Application.put_env(:qpbx, QPBX.Integrations, old || []) end)

      assert {422, %{"error" => %{"details" => %{"url" => ["must start with https://"]}}}} =
               api(k, :post, "/v1/webhooks", %{
                 url: "http://1.1.1.1/",
                 event_types: ["call.started"]
               })

      assert {422, %{"error" => %{"details" => %{"url" => ["points to an internal address"]}}}} =
               api(k, :post, "/v1/webhooks", %{
                 url: "https://[::ffff:127.0.0.1]/",
                 event_types: ["call.started"]
               })

      assert {201, %{"data" => %{"id" => id} = w, "secret" => "whsec_" <> _ = secret}} =
               api(k, :post, "/v1/webhooks", %{
                 url: "https://1.1.1.1/hook",
                 event_types: ["call.started"]
               })

      refute inspect(w) =~ secret
      assert {200, %{"data" => [_]}} = api(k, :get, "/v1/webhooks")

      assert {200, %{"data" => %{"enabled" => false}}} =
               api(k, :patch, "/v1/webhooks/#{id}", %{enabled: false})

      assert {200, %{"secret" => new}} = api(k, :post, "/v1/webhooks/#{id}/rotate-secret")
      assert new != secret

      {:ok, _} =
        QPBX.Integrations.update_webhook(
          scope,
          QPBX.Integrations.get_webhook(scope, id),
          %{enabled: true},
          {:system, "t"}
        )

      :ok =
        QPBX.Integrations.Webhooks.dispatch(%QPBX.Events.CallEvent{
          type: "started",
          tenant_id: t.id,
          call_id: "c1",
          at: DateTime.utc_now()
        })

      assert {200,
              %{"data" => [%{"id" => did, "status" => "pending", "event_type" => "call.started"}]}} =
               api(k, :get, "/v1/webhooks/#{id}/deliveries")

      assert {200, %{"data" => %{"payload" => payload}}} =
               api(k, :get, "/v1/webhook-deliveries/#{did}")

      assert %{"type" => "call.started", "data" => %{"call_id" => "c1"}} = Jason.decode!(payload)

      assert {201, %{"data" => %{"event_type" => "call.started"}}} =
               api(k, :post, "/v1/webhook-deliveries/#{did}/resend")

      other = key(Core.scope_for(user_fixture(tenant_fixture())), ~w(read write admin))
      assert {404, _} = api(other, :get, "/v1/webhooks/#{id}")
      assert {404, _} = api(other, :post, "/v1/webhook-deliveries/#{did}/resend")
      assert {403, _} = api(key(scope, ~w(read write)), :get, "/v1/webhooks")
      assert {204, nil} = api(k, :delete, "/v1/webhooks/#{id}")
    end

    test "calls: records by cursor, CSV export, daily usage", %{tok: k, t: t} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for n <- 1..3 do
        uuid = Ecto.UUID.generate()

        QPBX.Repo.insert!(%Telephony.Cdr{
          tenant_id: t.id,
          leg_uuid: uuid,
          call_uuid: uuid,
          leg: "a",
          direction: "internal",
          caller_number: "101",
          destination: "10#{n}",
          started_at: DateTime.add(now, -n * 60),
          ended_at: DateTime.add(now, -n * 60 + 5),
          duration: 5,
          billsec: 3,
          disposition: "answered"
        })
      end

      assert {200, %{"data" => [%{"destination" => "101"}, _], "next_cursor" => c}} =
               api(k, :get, "/v1/calls?limit=2")

      assert {200, %{"data" => [%{"destination" => "103"}], "next_cursor" => nil}} =
               api(k, :get, "/v1/calls?limit=2&cursor=#{c}")

      assert {400, _} = api(k, :get, "/v1/calls?cursor=bad")

      csv =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> k)
        |> get("/v1/calls/export?destination=x")

      assert csv.status == 200
      assert [_header, _, _, _] = String.split(csv.resp_body, "\r\n", trim: true)
      assert {200, %{"data" => _}} = api(k, :get, "/v1/usage/daily?days=7")
    end
  end
end
