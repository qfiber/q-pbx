defmodule QPBX.Core.UsersTest do
  use QPBX.DataCase, async: true
  import QPBX.Fixtures
  alias QPBX.Core

  @actor {:system, "test"}

  setup do
    t = tenant_fixture()
    admin = user_fixture(t, "tenant_admin")
    scope = Core.scope_for(admin)
    {:ok, e101} = Core.create_extension(scope, %{number: "101", name: "A"}, @actor)
    {:ok, e102} = Core.create_extension(scope, %{number: "102", name: "B"}, @actor)
    %{t: t, admin: admin, scope: scope, e101: e101, e102: e102}
  end

  test "invite with an extension; an extension moves from one user to another", %{
    scope: scope,
    admin: admin,
    e101: e101
  } do
    {:ok, u1} =
      Core.invite_user(
        scope,
        %{
          "name" => "U1",
          "email" => "u1@x.test",
          "role" => "tenant_user",
          "extension_id" => e101.id
        },
        admin
      )

    assert u1.extension_id == e101.id and Core.User.role(u1) == "tenant_user"
    {:ok, u2} = Core.invite_user(scope, %{"name" => "U2", "email" => "u2@x.test"}, admin)
    {:ok, u2} = Core.set_user_extension(scope, u2.id, e101.id, admin)
    assert u2.extension_id == e101.id
    assert Core.get_user(u1.id).extension_id == nil
    {:ok, u2} = Core.set_user_extension(scope, u2.id, "", admin)
    assert u2.extension_id == nil
  end

  test "another tenant's extension or user is out of reach", %{scope: scope, admin: admin} do
    other = Core.scope_for(user_fixture(tenant_fixture()))
    {:ok, foreign} = Core.create_extension(other, %{number: "101", name: "X"}, @actor)

    assert {:error, :no_such_extension} =
             Core.invite_user(
               scope,
               %{"name" => "U", "email" => "u@x.test", "extension_id" => foreign.id},
               admin
             )

    [them] = Core.list_tenant_users(other)
    assert {:error, :not_found} = Core.set_user_role(scope, them.id, "tenant_user", admin)
    assert {:error, :not_found} = Core.delete_user(scope, them.id, admin)
  end

  test "the last admin stays; nobody removes themselves", %{scope: scope, admin: admin} do
    assert {:error, :last_admin} = Core.set_user_role(scope, admin.id, "tenant_user", admin)
    assert {:error, :self} = Core.delete_user(scope, admin.id, admin)

    {:ok, other} =
      Core.invite_user(
        scope,
        %{"name" => "B", "email" => "b@x.test", "role" => "tenant_admin"},
        admin
      )

    {:ok, _} = Core.set_user_role(scope, admin.id, "tenant_user", admin)
    assert {:error, :last_admin} = Core.delete_user(Core.scope_for(admin), other.id, admin)
    {:ok, _} = Core.set_user_role(scope, admin.id, "tenant_admin", admin)
    {:ok, _} = Core.delete_user(scope, other.id, admin)
    assert Core.get_user(other.id) == nil
  end

  test "a tenant user changes only the call features of their own extension", %{
    scope: scope,
    admin: admin,
    e101: e101
  } do
    {:ok, u} =
      Core.invite_user(
        scope,
        %{"name" => "U", "email" => "u@x.test", "extension_id" => e101.id},
        admin
      )

    me = Core.scope_for(Core.get_user(u.id))
    assert Core.my_extension(me).id == e101.id

    {:ok, ext} =
      Core.update_my_extension(
        me,
        %{"dnd" => "true", "forward_busy" => "102", "number" => "999", "name" => "Hacked"},
        u
      )

    assert ext.dnd and ext.forward_busy == "102"
    assert ext.number == "101" and ext.name == "A"

    {:ok, unlinked} = Core.invite_user(scope, %{"name" => "V", "email" => "v@x.test"}, admin)
    none = Core.scope_for(Core.get_user(unlinked.id))
    assert Core.my_extension(none) == nil
    assert {:error, :no_extension} = Core.update_my_extension(none, %{"dnd" => "true"}, unlinked)
  end

  test "deleting the extension unlinks its user", %{scope: scope, admin: admin, e102: e102} do
    {:ok, u} =
      Core.invite_user(
        scope,
        %{"name" => "U", "email" => "u@x.test", "extension_id" => e102.id},
        admin
      )

    {:ok, _} = Core.delete_extension(scope, e102, admin)
    assert Core.get_user(u.id).extension_id == nil
  end
end
