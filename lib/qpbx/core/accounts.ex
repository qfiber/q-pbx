defmodule QPBX.Core.Accounts do
  @moduledoc "Platform admins and tenant users: creation, login, setup links and TOTP."
  import Ecto.Query
  alias Ecto.Multi
  alias QPBX.Core.{Audit, Credentials, PlatformAdmin, Tenant, User, UserRole}
  alias QPBX.Repo

  @setup_salt "account setup"
  @setup_max_age 48 * 3600
  @totp_issuer "Q-PBX"

  ## Creation

  def create_platform_admin(attrs, actor) do
    Multi.new()
    |> Multi.insert(:account, PlatformAdmin.changeset(%PlatformAdmin{locale: "en"}, attrs))
    |> Audit.add(
      actor,
      "platform_admin.create",
      :account,
      Map.drop(attrs_map(attrs), ["password"])
    )
    |> Audit.commit(:account)
  end

  def create_user(%Tenant{} = tenant, attrs, role, actor) do
    user_cs = User.changeset(%User{tenant_id: tenant.id}, attrs)
    role_cs = UserRole.changeset(%UserRole{tenant_id: tenant.id}, %{role: role})

    Multi.new()
    |> Multi.insert(:account, user_cs)
    |> Multi.insert(:role, fn %{account: user} ->
      Ecto.Changeset.put_change(role_cs, :user_id, user.id)
    end)
    |> Audit.add(actor, "user.create", :account, Map.put(user_cs.changes, :role, role))
    |> Audit.commit(:account)
    |> case do
      {:ok, user} -> {:ok, get_user!(user.id)}
      error -> error
    end
  end

  def change_user(attrs \\ %{}), do: User.changeset(%User{}, attrs)
  def change_platform_admin(attrs \\ %{}), do: PlatformAdmin.changeset(%PlatformAdmin{}, attrs)

  def get_platform_admin(id), do: Repo.get(PlatformAdmin, id)
  def get_user(id), do: User |> Repo.get(id) |> Repo.preload([:user_role, :tenant])
  def get_user!(id), do: User |> Repo.get!(id) |> Repo.preload([:user_role, :tenant])

  def list_users(%Tenant{id: tenant_id}),
    do:
      Repo.all(
        from u in User, where: u.tenant_id == ^tenant_id, order_by: u.email, preload: :user_role
      )

  ## Login

  def authenticate_platform_admin(email, password),
    do: authenticate(PlatformAdmin, email, password)

  def authenticate_user(email, password) do
    with {:ok, user} <- authenticate(User, email, password),
         do: {:ok, Repo.preload(user, [:user_role, :tenant])}
  end

  defp authenticate(schema, email, password) when is_binary(email) and is_binary(password) do
    account = Repo.get_by(schema, email: String.trim(email))
    if Credentials.valid_password?(account, password), do: {:ok, account}, else: :error
  end

  defp authenticate(_, _, _), do: :error

  ## Setup links (one-time: the token stops working once the password changes)

  def setup_token(account) do
    Plug.Crypto.sign(secret(), @setup_salt, {kind(account), account.id, fingerprint(account)})
  end

  def account_from_setup_token(token) when is_binary(token) do
    with {:ok, {kind, id, fp}} <-
           Plug.Crypto.verify(secret(), @setup_salt, token, max_age: @setup_max_age),
         %{} = account <- load(kind, id),
         true <- Plug.Crypto.secure_compare(fp, fingerprint(account)) do
      {:ok, account}
    else
      _ -> :error
    end
  end

  def account_from_setup_token(_), do: :error

  def change_password(account, attrs \\ %{}), do: Credentials.password_changeset(account, attrs)

  def complete_setup(account, attrs) do
    Multi.new()
    |> Multi.update(:account, Credentials.password_changeset(account, attrs))
    |> Audit.add(account, "account.setup", :account, %{})
    |> Audit.commit(:account)
  end

  defp fingerprint(%{hashed_password: hash}),
    do: :crypto.hash(:sha256, hash || "") |> binary_part(0, 12) |> Base.url_encode64()

  defp kind(%PlatformAdmin{}), do: :platform_admin
  defp kind(%User{}), do: :user
  defp load(:platform_admin, id), do: get_platform_admin(id)
  defp load(:user, id), do: get_user(id)

  ## TOTP

  def new_totp_secret, do: NimbleTOTP.secret()

  def totp_uri(account, secret),
    do: NimbleTOTP.otpauth_uri("#{@totp_issuer}:#{account.email}", secret, issuer: @totp_issuer)

  def totp_enabled?(%{totp_secret: secret}), do: is_binary(secret)

  @doc "Platform admins must use 2FA; tenant users once they have enrolled."
  def requires_totp?(%PlatformAdmin{}), do: true
  def requires_totp?(account), do: totp_enabled?(account)

  def enable_totp(account, secret, code) do
    if valid_code?(secret, code, nil) do
      changes = %{totp_secret: secret, totp_last_used_at: now()}

      Multi.new()
      |> Multi.update(:account, Ecto.Changeset.change(account, changes))
      |> Audit.add(account, "account.totp_enable", :account, %{})
      |> Audit.commit(:account)
    else
      {:error, :invalid_code}
    end
  end

  @doc "Checks a code and records its use, so the same code cannot be replayed."
  def verify_totp(%{totp_secret: secret} = account, code) when is_binary(secret) do
    if valid_code?(secret, code, account.totp_last_used_at) do
      account |> Ecto.Changeset.change(totp_last_used_at: now()) |> Repo.update()
    else
      {:error, :invalid_code}
    end
  end

  def verify_totp(_, _), do: {:error, :invalid_code}

  defp valid_code?(secret, code, since) when is_binary(code) do
    code = String.replace(code, ~r/\s/, "")
    now = System.os_time(:second)

    # The current and the previous 30 s window, to allow for a phone clock running slightly behind.
    String.match?(code, ~r/^\d{6}$/) and
      Enum.any?([now, now - 30], &NimbleTOTP.valid?(secret, code, since: since, time: &1))
  end

  defp valid_code?(_, _, _), do: false

  ## Helpers

  defp attrs_map(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp secret, do: Application.fetch_env!(:qpbx, :token_secret)
end
