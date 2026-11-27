defmodule QPBX.Core.Users do
  @moduledoc """
  A tenant's users, managed by its tenant admins (tenant scope): invite (a setup link is
  sent by the caller), the user's own extension, role, removal. The last tenant admin cannot
  be demoted or removed, and an admin cannot remove themselves. Tenant users reach their own
  extension through `my_extension/1` and `update_my_extension/3` (call features only).
  """
  import Ecto.Query

  alias QPBX.Core.{
    Accounts,
    Audit,
    Extension,
    Extensions,
    Scope,
    Sessions,
    Tenant,
    User,
    UserRole
  }

  alias QPBX.Repo

  # What a tenant user may change on their own extension.
  @own_fields ~w(dnd call_waiting forward_always forward_busy forward_no_answer no_answer_seconds
                 follow_me_enabled follow_me_numbers)

  def list(%Scope{kind: :tenant, tenant_id: tid} = scope) do
    Scope.run(scope, fn ->
      Repo.all(from u in User, where: u.tenant_id == ^tid, order_by: u.email, preload: :user_role)
    end)
  end

  @doc "Creates a user of the tenant, with a role and optionally an extension."
  def invite(%Scope{kind: :tenant, tenant_id: tid} = scope, attrs, actor) do
    role = attrs["role"] || attrs[:role] || "tenant_user"
    ext_id = blank(attrs["extension_id"] || attrs[:extension_id])
    tenant = Repo.get!(Tenant, tid)

    with :ok <- own_extension(scope, ext_id),
         {:ok, user} <- Accounts.create_user(tenant, attrs, role, actor) do
      if ext_id, do: link(scope, user, ext_id, actor), else: {:ok, user}
    end
  end

  @doc "Links a user to an extension of the tenant (nil: none)."
  def set_extension(%Scope{kind: :tenant} = scope, user_id, ext_id, actor) do
    ext_id = blank(ext_id)

    with %User{} = user <- get(scope, user_id) || {:error, :not_found},
         :ok <- own_extension(scope, ext_id) do
      link(scope, user, ext_id, actor)
    end
  end

  def set_role(%Scope{kind: :tenant} = scope, user_id, role, actor)
      when role in ["tenant_admin", "tenant_user"] do
    with %User{} = user <- get(scope, user_id) || {:error, :not_found},
         :ok <- keeps_an_admin(scope, user, role) do
      Scope.run(scope, fn ->
        user.user_role |> UserRole.changeset(%{role: role}) |> Repo.update!()
        Repo.insert!(Audit.entry(actor, "user.role", user, %{role: role}))
        {:ok, Accounts.get_user!(user.id)}
      end)
    end
  end

  @doc "Removes a user and ends their sessions."
  def delete(%Scope{kind: :tenant, account: me} = scope, user_id, actor) do
    with %User{} = user <- get(scope, user_id) || {:error, :not_found},
         true <- user.id != me.id || {:error, :self},
         :ok <- keeps_an_admin(scope, user, nil) do
      Sessions.revoke_all(user, actor)

      Scope.run(scope, fn ->
        Repo.delete!(user)

        Repo.insert!(
          Audit.entry(actor, "user.delete", nil, %{email: user.email, tenant_id: user.tenant_id})
        )

        {:ok, user}
      end)
    end
  end

  def setup_link(%Scope{kind: :tenant} = scope, user_id, actor) do
    with %User{} = user <- get(scope, user_id) || {:error, :not_found},
         {:ok, token} <- Accounts.issue_setup_link(user, actor) do
      {:ok, Accounts.get_user!(user.id), token}
    end
  end

  def sign_out(%Scope{kind: :tenant} = scope, user_id, actor) do
    with %User{} = user <- get(scope, user_id) || {:error, :not_found},
         do: Sessions.revoke_all(user, actor)
  end

  @doc "The signed-in user's own extension (with its devices), or nil."
  def my_extension(%Scope{kind: :tenant, account: %User{} = me} = scope) do
    case Repo.get(User, me.id) do
      %User{extension_id: id} when is_binary(id) -> Extensions.get!(scope, id)
      _ -> nil
    end
  end

  @doc "A tenant user changes the call features of their own extension (nothing else)."
  def update_my_extension(%Scope{kind: :tenant} = scope, attrs, actor) do
    case my_extension(scope) do
      nil -> {:error, :no_extension}
      ext -> Extensions.update(scope, ext, Map.take(attrs, @own_fields), actor)
    end
  end

  defp link(%Scope{tenant_id: tid} = scope, user, ext_id, actor) do
    Scope.run(scope, fn ->
      # The extension moves from whoever had it.
      if ext_id,
        do:
          Repo.update_all(
            from(u in User, where: u.tenant_id == ^tid and u.extension_id == ^ext_id),
            set: [extension_id: nil]
          )

      user = user |> Ecto.Changeset.change(extension_id: ext_id) |> Repo.update!()
      Repo.insert!(Audit.entry(actor, "user.extension", user, %{extension_id: ext_id}))
      {:ok, Accounts.get_user!(user.id)}
    end)
  end

  defp get(%Scope{tenant_id: tid} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Scope.run(scope, fn ->
          Repo.one(
            from u in User, where: u.id == ^id and u.tenant_id == ^tid, preload: :user_role
          )
        end)

      :error ->
        nil
    end
  end

  defp own_extension(_scope, nil), do: :ok

  defp own_extension(%Scope{tenant_id: tid} = scope, ext_id) do
    found =
      case Ecto.UUID.cast(ext_id) do
        {:ok, id} ->
          Scope.run(scope, fn ->
            Repo.exists?(from e in Extension, where: e.id == ^id and e.tenant_id == ^tid)
          end)

        :error ->
          false
      end

    if found, do: :ok, else: {:error, :no_such_extension}
  end

  # Demoting or removing `user` must leave the tenant at least one admin.
  defp keeps_an_admin(%Scope{tenant_id: tid} = scope, %User{} = user, new_role) do
    if User.role(user) == "tenant_admin" and new_role != "tenant_admin" do
      admins =
        Scope.run(scope, fn ->
          Repo.aggregate(
            from(r in UserRole, where: r.tenant_id == ^tid and r.role == "tenant_admin"),
            :count
          )
        end)

      if admins > 1, do: :ok, else: {:error, :last_admin}
    else
      :ok
    end
  end

  defp blank(""), do: nil
  defp blank(v), do: v
end
