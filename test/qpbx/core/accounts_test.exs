defmodule QPBX.Core.AccountsTest do
  use QPBX.DataCase, async: true
  import QPBX.Fixtures
  alias QPBX.Core
  alias QPBX.Core.{AuditLog, User}

  @actor {:system, "test"}

  describe "creating accounts" do
    test "a tenant admin belongs to one tenant with a role, and the change is audited" do
      tenant = tenant_fixture()

      {:ok, user} =
        Core.create_user(tenant, %{email: "a@acme.test", name: "A"}, "tenant_admin", @actor)

      assert user.tenant_id == tenant.id
      assert User.role(user) == "tenant_admin"
      assert user.hashed_password == nil

      [entry] = Repo.all(from a in AuditLog, where: a.action == "user.create")
      assert entry.tenant_id == tenant.id
      assert entry.target_id == user.id
      assert entry.actor_type == "system:test"
    end

    test "rejects unknown roles and duplicate emails (case-insensitive)" do
      tenant = tenant_fixture()

      assert {:error, _} =
               Core.create_user(tenant, %{email: "b@x.test", name: "B"}, "root", @actor)

      {:ok, _} = Core.create_user(tenant, %{email: "c@x.test", name: "C"}, "tenant_user", @actor)

      assert {:error, cs} =
               Core.create_user(
                 tenant_fixture(),
                 %{email: "C@X.test", name: "C"},
                 "tenant_user",
                 @actor
               )

      assert errors_on(cs)[:email]
    end

    test "audit entries never contain passwords or TOTP secrets" do
      admin = platform_admin_fixture()
      secret = Core.new_totp_secret()
      {:ok, _} = Core.enable_totp(admin, secret, totp_code(secret))

      for entry <- Repo.all(AuditLog) do
        refute Map.has_key?(entry.changes, "hashed_password")
        refute Map.has_key?(entry.changes, "password")
        refute Map.has_key?(entry.changes, "totp_secret")
      end
    end
  end

  describe "login" do
    test "accepts the right password and rejects wrong ones and unknown users" do
      user = user_fixture()
      assert {:ok, %User{id: id}} = Core.authenticate_user(String.upcase(user.email), password())
      assert id == user.id
      assert :error = Core.authenticate_user(user.email, "wrong password!!")
      assert :error = Core.authenticate_user("nobody@example.com", password())
      assert :error = Core.authenticate_platform_admin(user.email, password())
    end

    test "an account that has not completed setup cannot log in" do
      {:ok, user} =
        Core.create_user(
          tenant_fixture(),
          %{email: "new@x.test", name: "N"},
          "tenant_user",
          @actor
        )

      assert :error = Core.authenticate_user(user.email, "")
    end
  end

  describe "setup links" do
    test "work once, then stop working after the password is set" do
      {:ok, user} =
        Core.create_user(
          tenant_fixture(),
          %{email: "s@x.test", name: "S"},
          "tenant_admin",
          @actor
        )

      token = Core.setup_token(user)
      assert {:ok, %User{id: id}} = Core.account_from_setup_token(token)
      assert id == user.id

      {:ok, _} =
        Core.complete_setup(user, %{password: password(), password_confirmation: password()})

      assert :error = Core.account_from_setup_token(token)
    end

    test "reject tampered tokens and weak or mismatched passwords" do
      user = user_fixture()
      assert :error = Core.account_from_setup_token(Core.setup_token(user) <> "x")
      assert :error = Core.account_from_setup_token(nil)

      assert {:error, cs} =
               Core.complete_setup(user, %{password: "short", password_confirmation: "short"})

      assert errors_on(cs)[:password]

      assert {:error, cs} =
               Core.complete_setup(user, %{
                 password: password(),
                 password_confirmation: "other one!!!!"
               })

      assert errors_on(cs)[:password_confirmation]
    end
  end

  describe "TOTP" do
    test "platform admins always require it, tenant users once enrolled" do
      assert Core.requires_totp?(platform_admin_fixture())
      user = user_fixture()
      refute Core.requires_totp?(user)
      secret = Core.new_totp_secret()
      {:ok, user} = Core.enable_totp(user, secret, totp_code(secret))
      assert Core.requires_totp?(user)
    end

    test "enrolment needs a valid code; the secret is stored encrypted" do
      user = user_fixture()
      secret = Core.new_totp_secret()
      assert {:error, :invalid_code} = Core.enable_totp(user, secret, "000000")
      {:ok, _} = Core.enable_totp(user, secret, totp_code(secret))

      %{rows: [[raw]]} =
        Repo.query!("SELECT totp_secret FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])

      refute raw == secret
      assert Core.get_user(user.id).totp_secret == secret
    end

    test "a code is accepted once and cannot be replayed" do
      user = user_fixture()
      secret = Core.new_totp_secret()
      # Enrol with the previous window's code so the current window is still unused.
      {:ok, user} = Core.enable_totp(user, secret, totp_code(secret, -1))

      user =
        Repo.update!(
          Ecto.Changeset.change(user,
            totp_last_used_at:
              DateTime.add(user.totp_last_used_at, -60) |> DateTime.truncate(:second)
          )
        )

      code = totp_code(secret)
      assert {:ok, user} = Core.verify_totp(user, code)
      assert {:error, :invalid_code} = Core.verify_totp(user, code)
      assert {:error, :invalid_code} = Core.verify_totp(user, "12345")
    end
  end

  describe "row-level security" do
    test "inside a tenant scope, rows of other tenants are invisible even without a filter" do
      a = user_fixture(tenant_fixture())
      b = user_fixture(tenant_fixture())

      {:ok, ids} = Core.with_tenant(a.tenant_id, fn -> Repo.all(from u in User, select: u.id) end)
      assert a.id in ids
      refute b.id in ids

      # Writing a row for another tenant is refused too.
      assert_raise Postgrex.Error, ~r/row-level security/, fn ->
        Core.with_tenant(a.tenant_id, fn ->
          Repo.insert!(%User{tenant_id: b.tenant_id, email: "x@y.test", name: "X"})
        end)
      end

      # After a scoped transaction the connection's setting is '' (not unset); queries must
      # still work. Run a few on the same connection to catch a bad uuid cast in the policy.
      for _ <- 1..5, do: Repo.all(from u in User, where: u.email == "nobody", select: u.id)

      # Outside a scope (platform admin, jobs) every row is visible again.
      all = Repo.all(from u in User, select: u.id)
      assert a.id in all and b.id in all
    end
  end
end
