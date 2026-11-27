defmodule QPBX.Web.TelephonyPagesTest do
  use QPBX.Web.ConnCase, async: false
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.Core

  @actor {:system, "test"}

  defp signed_in(conn, account, login_path) do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, login_path, login: %{email: account.email, password: password()})
    conn = post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)})
    recycle(conn)
  end

  setup %{conn: conn} do
    tenant = tenant_fixture()
    admin = user_fixture(tenant, "tenant_admin")
    %{conn: conn, tenant: tenant, admin: admin, scope: Core.scope_for(admin)}
  end

  describe "tenant admin pages" do
    setup %{conn: conn, admin: admin}, do: %{conn: signed_in(conn, admin, ~p"/login")}

    test "create an extension, add a device, see its password once", %{conn: conn, tenant: t} do
      {:ok, view, _} = live(conn, ~p"/app/extensions")

      view
      |> form("#extension-form", extension: %{number: "101", name: "Reception"})
      |> render_submit()

      {path, _} = assert_redirect(view)
      {:ok, view, _} = live(conn, path)

      html =
        view
        |> form("#device-form", device: %{label: "desk", kind: "desk_phone"})
        |> render_submit()

      assert html =~ "101-desk"

      password =
        view
        |> element("#secret-password")
        |> render()
        |> then(&Regex.run(~r/>([^<]+)</, &1))
        |> List.last()

      assert String.length(password) == 24
      assert html =~ t.sip_domain

      # Gone after "Done" and on a fresh load.
      refute view |> element("#device-secret button") |> render_click() =~ password
      {:ok, _view, html} = live(conn, path)
      refute html =~ password
    end

    test "call features accept local number formats", %{conn: conn, scope: scope} do
      {:ok, ext} = Core.create_extension(scope, %{number: "102", name: "Sales"}, @actor)
      {:ok, view, _} = live(conn, ~p"/app/extensions/#{ext.id}")

      view
      |> form("#extension-form",
        extension: %{forward_busy: "02-123-4567", follow_me_text: "103, 050-123-4567"}
      )
      |> render_submit()

      ext = Core.get_extension!(scope, ext.id)
      assert ext.forward_busy == "+97221234567"
      assert ext.follow_me_numbers == ["103", "+972501234567"]

      html =
        view
        |> form("#extension-form", extension: %{forward_always: "not a number"})
        |> render_submit()

      assert html =~ "an extension or an E.164 number"
    end

    test "an outbound route with trunks in failover order", %{conn: conn, scope: scope} do
      platform = Core.scope_for(platform_admin_fixture())

      {:ok, a} =
        Core.create_trunk(
          platform,
          %{name: "Partner", auth_mode: "ip", addresses: [%{host: "192.0.2.61"}]},
          @actor
        )

      {:ok, b} =
        Core.create_trunk(
          platform,
          %{name: "Cellcom", auth_mode: "ip", addresses: [%{host: "192.0.2.62"}]},
          @actor
        )

      {:ok, view, _} = live(conn, ~p"/app/routes")

      html =
        view
        |> form("#route-form",
          route: %{
            name: "Israel",
            prefixes_text: "+972",
            destination_class: "local",
            trunk_1: a.id,
            trunk_2: b.id
          }
        )
        |> render_submit()

      assert html =~ "Partner → Cellcom"
      assert [%{trunk_ids: ids}] = Core.list_routes(scope)
      assert ids == [a.id, b.id]
    end

    test "numbers: point a number at an extension", %{conn: conn, scope: scope, tenant: t} do
      platform = Core.scope_for(platform_admin_fixture())

      {:ok, trunk} =
        Core.create_trunk(
          platform,
          %{name: "P", auth_mode: "ip", addresses: [%{host: "192.0.2.63"}]},
          @actor
        )

      {:ok, did} =
        Core.create_did(
          platform,
          %{number: "+97221234567", trunk_id: trunk.id, tenant_id: t.id},
          @actor
        )

      {:ok, ext} = Core.create_extension(scope, %{number: "101", name: "Reception"}, @actor)
      {:ok, view, html} = live(conn, ~p"/app/numbers")
      assert html =~ "021234567"

      view
      |> form("#did-form-#{did.id}",
        did: %{destination_type: "extension", destination_id: ext.id}
      )
      |> render_submit()

      assert Core.get_did!(scope, did.id).destination_id == ext.id
    end

    test "office IPs are tenant SIP allow entries; too-wide prefixes refused", %{
      conn: conn,
      tenant: t
    } do
      {:ok, view, _} = live(conn, ~p"/app/office-ips")

      html =
        view
        |> form("#office-ip-form", entry: %{cidr: "198.51.100.0/8", reason: "too wide"})
        |> render_submit()

      assert html =~ "too wide for a tenant entry"

      view
      |> form("#office-ip-form", entry: %{cidr: "198.51.100.9", reason: "HQ"})
      |> render_submit()

      assert [%{kind: "allow", scope: "sip", tenant_id: tid}] =
               QPBX.Firewall.list_entries(level: "tenant", tenant_id: t.id)

      assert tid == t.id
    end

    test "number format override and reset", %{conn: conn, scope: scope} do
      {:ok, view, _} = live(conn, ~p"/app/number-format")

      view
      |> form("#number-format-form", rule: %{country_code: "972", area_code: "3"})
      |> render_submit()

      assert Core.to_e164(scope, "1234567") == {:ok, "+97231234567"}
      view |> element("#reset-format") |> render_click()
      assert Core.to_e164(scope, "1234567") == :error
    end
  end

  test "a tenant user (not admin) cannot open the configuration pages", %{conn: conn, tenant: t} do
    user = user_fixture(t, "tenant_user")
    conn = post(conn, ~p"/login", login: %{email: user.email, password: password()})
    conn = recycle(conn)
    assert {:error, {:redirect, %{to: "/app"}}} = live(conn, ~p"/app/extensions")
  end

  describe "platform pages" do
    setup %{conn: conn},
      do: %{conn: signed_in(conn, platform_admin_fixture(), ~p"/platform/login")}

    test "a trunk with two addresses; editing keeps the stored password", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/platform/trunks/new")

      # The "Add address" button dispatches a change event carrying addresses_sort "new".
      html =
        render_change(view, "validate", %{
          "trunk" => %{"name" => "Partner", "addresses_sort" => ["0", "new"]}
        })

      assert html =~ "trunk[addresses][1][host]"

      view
      |> form("#trunk-form",
        trunk: %{
          name: "Partner",
          auth_mode: "registration",
          username: "acct",
          password: "carrier-secret",
          addresses: %{
            "0" => %{host: "192.0.2.71"},
            "1" => %{host: "sip.partner.example", priority: 2}
          }
        }
      )
      |> render_submit()

      platform = Core.scope_for(platform_admin_fixture())
      [trunk] = Core.list_trunks(platform)
      assert Enum.map(trunk.addresses, & &1.host) == ["192.0.2.71", "sip.partner.example"]

      {:ok, view, html} = live(conn, ~p"/platform/trunks/#{trunk.id}")
      refute html =~ "carrier-secret"
      view |> form("#trunk-form", trunk: %{name: "Partner IL", password: ""}) |> render_submit()
      assert Core.get_trunk!(platform, trunk.id).password == "carrier-secret"
    end

    test "numbers, classes and emergency routes", %{conn: conn, tenant: t} do
      platform = Core.scope_for(platform_admin_fixture())

      {:ok, trunk} =
        Core.create_trunk(
          platform,
          %{name: "P", auth_mode: "ip", addresses: [%{host: "192.0.2.72"}]},
          @actor
        )

      {:ok, view, _} = live(conn, ~p"/platform/numbers")

      view
      |> form("#did-form", did: %{number: "02-765-4321", trunk_id: trunk.id, tenant_id: t.id})
      |> render_submit()

      assert [%{number: "+97227654321"}] = Core.list_dids(platform)

      {:ok, view, _} = live(conn, ~p"/platform/numbering")

      view
      |> form("#class-form", number_class: %{prefix: "+9725", class: "mobile"})
      |> render_submit()

      view
      |> form("#emergency-form", emergency_route: %{number: "100", trunk_id: trunk.id})
      |> render_submit()

      assert [%{prefix: "+9725"}] = Core.list_number_classes()
      assert [%{number: "100"}] = Core.list_emergency_routes()
    end
  end
end
