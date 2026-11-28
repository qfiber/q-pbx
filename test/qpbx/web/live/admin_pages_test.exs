defmodule QPBX.Web.AdminPagesTest do
  @moduledoc "What used to need the CLI: tenant editing, platform admins, setup links, sign-outs, audit log."
  use QPBX.Web.ConnCase, async: true
  use Oban.Testing, repo: QPBX.Repo
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Web.{Pager, PlanFields}

  defp signed_in(conn, account, login_path) do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, login_path, login: %{email: account.email, password: password()})
    conn = post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)})
    {recycle(conn), account}
  end

  describe "platform admin" do
    setup %{conn: conn} do
      {conn, admin} = signed_in(conn, platform_admin_fixture(), ~p"/platform/login")
      %{conn: conn, admin: admin}
    end

    test "edits a tenant: plan, name and a limit override; adds a tenant admin; setup link; sign out",
         %{conn: conn} do
      plan = plan_fixture(%{name: "Small", max_extensions: 5})
      big = plan_fixture(%{name: "Big", max_extensions: 50})
      t = tenant_fixture(plan_id: plan.id)
      user = user_fixture(t, "tenant_user")
      {_token, _session} = Core.create_session(user)

      {:ok, view, _} = live(conn, ~p"/platform/tenants")
      view |> element("#tenant-#{t.id}") |> render_click()
      {:ok, view, html} = live(conn, ~p"/platform/tenants/#{t.id}")
      assert html =~ user.email

      view
      |> form("#tenant-form",
        tenant: %{name: "Renamed", plan_id: big.id, override_max_extensions: "7"}
      )
      |> render_submit()

      t = Core.get_tenant!(t.id)
      assert t.name == "Renamed" and t.plan_id == big.id
      assert Core.effective_limits(t)[:max_extensions] == 7
      # Clearing the field goes back to the plan's value.
      view |> form("#tenant-form", tenant: %{override_max_extensions: ""}) |> render_submit()
      assert Core.effective_limits(Core.get_tenant!(t.id))[:max_extensions] == 50

      view
      |> form("#tenant-admin-form", admin: %{name: "Second", email: "second@x.test"})
      |> render_submit()

      assert Core.User.role(Core.find_account_by_email("second@x.test")) == "tenant_admin"
      assert render(view) =~ "/setup/"

      view |> element("#setup-link-#{user.id}") |> render_click()

      assert Enum.any?(
               all_enqueued(worker: QPBX.Notify.SetupLinkEmail),
               &(&1.args["email"] == user.email)
             )

      assert view |> element("#sign-out-#{user.id}") |> render_click() =~
               "Signed out of 1 sessions."

      assert Core.list_sessions(user) == []
    end

    test "usage alert thresholds: on a plan, and a tenant's own (empty: the plan's)", %{
      conn: conn
    } do
      plan = plan_fixture(%{name: "Usage"})
      {:ok, view, _} = live(conn, ~p"/platform/plans/#{plan.id}")

      assert view |> form("#plan-form", plan: %{usage_thresholds: "70, 120"}) |> render_submit() =~
               "must be percentages from 1 to 100"

      view |> form("#plan-form", plan: %{usage_thresholds: "90, 60"}) |> render_submit()
      assert Core.get_plan!(plan.id).usage_thresholds == [60, 90]

      t = tenant_fixture(plan_id: plan.id)
      {:ok, view, html} = live(conn, ~p"/platform/tenants/#{t.id}")
      assert html =~ ~s(placeholder="60, 90")
      view |> form("#tenant-form", tenant: %{usage_thresholds: "25"}) |> render_submit()
      assert Core.usage_thresholds(Core.get_tenant!(t.id)) == [25]
      view |> form("#tenant-form", tenant: %{usage_thresholds: ""}) |> render_submit()
      assert Core.usage_thresholds(Core.get_tenant!(t.id)) == [60, 90]
    end

    test "every plan limit has a place in the grouped fields" do
      assert Enum.sort(PlanFields.grouped()) == Enum.sort(QPBX.Core.Plan.limits())
    end

    test "pages of 25: the pager, a page from the URL, numbers with gaps" do
      list = for i <- 1..60, do: %{id: i}
      p = Pager.paginate(list, "3")
      assert %{page: 3, pages: 3, total: 60} = p
      assert length(p.items) == 10
      assert Pager.paginate(list, "x").page == 1
      assert Pager.paginate(list, "99").page == 3
      assert Pager.page_of(list, 26) == 2
      assert Pager.numbers(%{page: 5, pages: 20}) == [1, :gap, 3, 4, 5, 6, 7, :gap, 20]
    end

    test "the tenant list shows 25 a page", %{conn: conn} do
      for i <- 1..27, do: tenant_fixture(%{name: "Pg #{String.pad_leading("#{i}", 2, "0")}"})
      {:ok, view, html} = live(conn, ~p"/platform/tenants")
      assert html =~ "1–25 of"
      assert has_element?(view, "#tenants-pages a", "2")
      {:ok, _view, html} = live(conn, ~p"/platform/tenants?page=2")
      assert html =~ "26–"
    end

    test "the tenant list: search by name or domain", %{conn: conn} do
      a = tenant_fixture(%{name: "Alpha Dental"})
      b = tenant_fixture(%{name: "Beta Law"})
      {:ok, view, _} = live(conn, ~p"/platform/tenants")
      assert has_element?(view, "#tenant-#{a.id}") and has_element?(view, "#tenant-#{b.id}")
      view |> form("#tenant-search", q: "alpha") |> render_change()
      assert has_element?(view, "#tenant-#{a.id}")
      refute has_element?(view, "#tenant-#{b.id}")
    end

    test "adds a platform admin and sends a new setup link", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/platform/admins")

      html =
        view |> form("#admin-form", admin: %{name: "Ops", email: "ops@x.test"}) |> render_submit()

      assert html =~ "ops@x.test" and html =~ "/setup/"
      ops = Core.find_account_by_email("ops@x.test")
      assert %Core.PlatformAdmin{} = ops
      view |> element("#setup-link-#{ops.id}") |> render_click()

      assert length(
               Enum.filter(
                 all_enqueued(worker: QPBX.Notify.SetupLinkEmail),
                 &(&1.args["email"] == "ops@x.test")
               )
             ) == 2
    end

    test "reads the audit log, all or by tenant", %{conn: conn, admin: admin} do
      a = tenant_fixture(name: "Alpha Co")
      b = tenant_fixture(name: "Beta Co")
      {:ok, _} = Core.update_tenant(a, %{name: "Alpha Two"}, admin)
      {:ok, _} = Core.update_tenant(b, %{name: "Beta Two"}, admin)
      {:ok, view, html} = live(conn, ~p"/platform/audit")
      assert html =~ "tenant.update" and html =~ admin.email
      view |> form("#audit-filter", f: %{tenant: a.id}) |> render_change()
      table = view |> element("#audit") |> render()
      assert table =~ "Alpha Two"
      refute table =~ "Beta Two"
    end
  end

  test "a tenant admin: own audit log only; setup link and sign-out for own users", %{conn: conn} do
    t = tenant_fixture()
    {conn, admin} = signed_in(conn, user_fixture(t, "tenant_admin"), ~p"/login")
    scope = Core.scope_for(admin)
    {:ok, _} = Core.create_extension(scope, %{number: "101", name: "Mine"}, admin)
    other = Core.scope_for(user_fixture(tenant_fixture()))
    {:ok, _} = Core.create_extension(other, %{number: "101", name: "Theirs"}, {:system, "test"})

    {:ok, _view, html} = live(conn, ~p"/app/audit")
    assert html =~ "extension.create" and html =~ "Mine"
    refute html =~ "Theirs"

    user = user_fixture(t, "tenant_user")
    {_token, _session} = Core.create_session(user)
    {:ok, view, _} = live(conn, ~p"/app/users")
    view |> element("#setup-link-#{user.id}") |> render_click()

    assert Enum.any?(
             all_enqueued(worker: QPBX.Notify.SetupLinkEmail),
             &(&1.args["email"] == user.email)
           )

    view |> element("#sign-out-#{user.id}") |> render_click()
    assert Core.list_sessions(user) == []

    [stranger] = Core.list_tenant_users(other)
    assert {:error, :not_found} = Core.sign_out_user(scope, stranger.id, admin)
    assert {:error, :not_found} = Core.user_setup_link(scope, stranger.id, admin)
  end
end
