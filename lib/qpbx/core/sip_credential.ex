defmodule QPBX.Core.SipCredential do
  @moduledoc """
  A SIP digest login of a tenant (used by a device or a registration). Only HA1 is stored:
  `md5(username:sip_domain:password)`, which Kamailio checks digests against. The password is
  generated, shown once, and never stored.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sip_credentials" do
    field :tenant_id, :binary_id
    field :username, :string
    field :ha1, :string, redact: true
    field :enabled, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  @doc "Usernames: letters, digits, dot, dash and underscore; 1 to 64 characters."
  def changeset(cred, attrs) do
    cred
    |> cast(attrs, [:username, :enabled])
    |> validate_required([:username])
    |> validate_format(:username, ~r/\A[A-Za-z0-9._-]{1,64}\z/,
      message: "letters, digits, dot, dash or underscore"
    )
    |> unique_constraint([:tenant_id, :username], error_key: :username)
  end

  # sobelow_skip ["Crypto.WeakHash"]
  # MD5 is what SIP digest authentication (RFC 3261/2617) uses and what phones support; the
  # password is a 24-character random secret and is never stored. SHA-256 digest (RFC 8760)
  # can be added for clients that support it.
  @doc "HA1 for digest authentication (RFC 2617), with the tenant's SIP domain as realm."
  def ha1(username, domain, password),
    do: :crypto.hash(:md5, "#{username}:#{domain}:#{password}") |> Base.encode16(case: :lower)

  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"

  @doc """
  A new random password: 24 characters from an unambiguous alphabet (about 139 bits), drawn
  from the cryptographic generator with rejection sampling so every character is equally likely.
  """
  def generate_password, do: draw(24, [])

  defp draw(0, acc), do: List.to_string(acc)

  defp draw(n, acc) do
    n_alpha = length(@alphabet)
    limit = 256 - rem(256, n_alpha)
    <<b>> = :crypto.strong_rand_bytes(1)
    if b < limit, do: draw(n - 1, [Enum.at(@alphabet, rem(b, n_alpha)) | acc]), else: draw(n, acc)
  end
end
