defmodule QPBX.Web.UsersPagesTest do
  use QPBX.Web.ConnCase, async: false
  use Oban.Testing, repo: QPBX.Repo
  import Phoenix.LiveViewTest
  import QPBX.Fixtures
  alias QPBX.{Core, Telephony}
  alias QPBX.Telephony.{Cdrs, Voicemail}

  @actor {:system, "test"}
  @mp3 <<"ID3", 4, 0, 0, 0, 0, 0, 0>> <> :binary.copy(<<9>>, 64)

  defp signed_in(conn, account) do
    secret = Core.new_totp_secret()
    {:ok, account} = Core.enable_totp(account, secret, totp_code(secret, -1))
    QPBX.Repo.update!(Ecto.Changeset.change(account, totp_last_used_at: ~U[2000-01-01 00:00:00Z]))
    conn = post(conn, ~p"/login", login: %{email: account.email, password: password()})
    conn = post(recycle(conn), ~p"/2fa", totp: %{code: totp_code(secret)})
    recycle(conn)
  end

  setup do
    t = tenant_fixture()
    admin = user_fixture(t, "tenant_admin")
    scope = Core.scope_for(admin)
    {:ok, e101} = Core.create_extension(scope, %{number: "101", name: "Dana"}, @actor)
    {:ok, e102} = Core.create_extension(scope, %{number: "102", name: "Eli"}, @actor)
    %{t: t, admin: admin, scope: scope, e101: e101, e102: e102}
  end

  test "a tenant admin invites a user with an extension, moves it, changes the role",
       %{conn: conn, admin: admin, e101: e101, e102: e102} do
    {:ok, view, _} = live(signed_in(conn, admin), ~p"/app/users")

    html =
      view
      |> form("#invite-form",
        user: %{name: "Dana", email: "dana@x.test", role: "tenant_user", extension_id: e101.id}
      )
      |> render_submit()

    assert html =~ "dana@x.test is invited"
    [job] = all_enqueued(worker: QPBX.Notify.SetupLinkEmail)
    assert job.args["email"] == "dana@x.test"
    dana = Core.find_account_by_email("dana@x.test")
    assert dana.extension_id == e101.id

    view |> form("#ext-#{dana.id}", %{user_id: dana.id, extension_id: e102.id}) |> render_change()
    assert Core.get_user(dana.id).extension_id == e102.id
    view |> form("#role-#{dana.id}", %{user_id: dana.id, role: "tenant_admin"}) |> render_change()
    assert Core.User.role(Core.get_user(dana.id)) == "tenant_admin"

    html =
      view
      |> form("#role-#{admin.id}", %{user_id: admin.id, role: "tenant_user"})
      |> render_change()

    refute html =~ "at least one tenant admin", "two admins now: demoting one is fine"
  end

  test "a tenant user: their own voicemail, calls and forwarding; nothing of others",
       %{conn: conn, t: t, admin: admin, scope: scope, e101: e101, e102: e102} do
    # An invited user has no password until the setup link; this one has.
    {:ok, user} =
      Core.set_user_extension(scope, user_fixture(t, "tenant_user").id, e101.id, admin)

    for e <- [e101, e102],
        do: {:ok, _} = Telephony.save_mailbox(scope, e.id, %{pin: "4831"}, admin)

    {:ok, mine} =
      Voicemail.store_system(Voicemail.mailbox_system(t.id, e101.id), @mp3, %{
        duration: 4,
        format: "mp3",
        caller_number: "0501112222"
      })

    {:ok, theirs} =
      Voicemail.store_system(Voicemail.mailbox_system(t.id, e102.id), @mp3, %{
        duration: 5,
        format: "mp3",
        caller_number: "0503334444"
      })

    leg = fn vars ->
      Cdrs.from_json(%{
        "variables" =>
          Map.merge(
            %{
              "uuid" => Ecto.UUID.generate(),
              "qpbx_tenant" => t.id,
              "start_epoch" => "#{System.os_time(:second)}",
              "end_epoch" => "#{System.os_time(:second) + 9}",
              "billsec" => "9",
              "answer_epoch" => "#{System.os_time(:second)}"
            },
            vars
          )
      })
    end

    Cdrs.insert_batch(
      [
        leg.(%{"qpbx_caller" => "101", "qpbx_destination" => "0501234567"}),
        leg.(%{"qpbx_caller" => "102", "qpbx_destination" => "0509999999"})
      ],
      %{t.id => t.timezone}
    )

    conn = signed_in(conn, Core.get_user(user.id))
    {:ok, view, html} = live(conn, ~p"/app/me")
    assert html =~ "Extension 101" and html =~ "0501112222" and html =~ "0501234567"
    refute html =~ "0503334444" or html =~ "0509999999"

    assert get(conn, ~p"/app/voicemail/#{mine.id}/audio").status == 200
    assert get(conn, ~p"/app/voicemail/#{theirs.id}/audio").status == 404

    view
    |> form("#my-extension-form", extension: %{dnd: "true", forward_busy: "102"})
    |> render_submit()

    assert %{dnd: true, forward_busy: "102"} = Core.get_extension!(scope, e101.id)

    # The Call button: refused targets are explained; 101 has no phone yet, so nothing rings.
    assert view |> form("#call-form", call: %{to: "abc"}) |> render_submit() =~
             "not a number Q-PBX can call"

    assert view |> form("#call-form", call: %{to: "102"}) |> render_submit() =~ "no phone to ring"

    # Admin pages stay closed to tenant users.
    assert {:error, {:redirect, %{to: "/app"}}} = live(conn, ~p"/app/users")
  end

  test "a tenant user without an extension is told so", %{conn: conn, t: t} do
    {:ok, _view, html} = live(signed_in(conn, user_fixture(t, "tenant_user")), ~p"/app/me")
    assert html =~ "No extension is linked to your account yet"
  end
end
