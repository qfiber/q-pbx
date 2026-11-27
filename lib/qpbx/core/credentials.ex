defmodule QPBX.Core.Credentials do
  @moduledoc """
  Fields and changesets shared by platform admins and tenant users:
  password (Argon2) and TOTP 2FA.
  """
  import Ecto.Changeset

  @min_password 12
  @max_password 256

  defmacro fields do
    quote do
      field :email, :string
      field :name, :string
      field :hashed_password, :string, redact: true
      field :password, :string, virtual: true, redact: true
      field :locale, :string
      field :totp_secret, QPBX.Core.Encrypted.Binary, redact: true
      field :totp_last_used_at, :utc_datetime
    end
  end

  def profile_changeset(cs) do
    cs
    |> validate_required([:email, :name])
    |> update_change(:email, &String.trim/1)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> validate_length(:name, max: 200)
    |> validate_inclusion(:locale, QPBX.Core.locales())
    |> unsafe_validate_unique(:email, QPBX.Repo)
    |> unique_constraint(:email)
  end

  def password_changeset(account, attrs) do
    account
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: @min_password, max: @max_password)
    |> validate_confirmation(:password, message: "does not match")
    |> then(fn cs ->
      case cs do
        %{valid?: true, changes: %{password: pw}} ->
          cs |> put_change(:hashed_password, Argon2.hash_pwd_salt(pw)) |> delete_change(:password)

        cs ->
          cs
      end
    end)
  end

  def valid_password?(%{hashed_password: hash}, password)
      when is_binary(hash) and is_binary(password),
      do: Argon2.verify_pass(password, hash)

  # Same work as a real check, so timing does not reveal whether an account exists.
  def valid_password?(_, _), do: Argon2.no_user_verify()
end
