defmodule QPBX.Telephony.Voicemail.Mailbox do
  @moduledoc "An extension's mailbox: PIN (hashed), email for new messages."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "mailboxes" do
    field :tenant_id, :binary_id
    field :extension_id, :binary_id
    field :enabled, :boolean, default: true
    field :pin, :string, virtual: true, redact: true
    field :pin_hash, :string, redact: true
    field :email, :string
    field :attach_audio, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  def changeset(mb, attrs) do
    mb
    |> cast(attrs, [:enabled, :pin, :email, :attach_audio])
    |> update_change(:email, &(&1 && String.trim(&1)))
    |> validate_format(:email, ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
    |> validate_length(:email, max: 254)
    |> validate_format(:pin, ~r/\A\d{4,10}\z/, message: "4 to 10 digits")
    |> validate_pin_strength()
    |> hash_pin()
    |> validate_required([:pin_hash], message: "set a PIN")
    |> unique_constraint(:extension_id)
  end

  # The obvious ones are what scanners try first.
  defp validate_pin_strength(cs) do
    validate_change(cs, :pin, fn :pin, pin ->
      digits = String.graphemes(pin)

      weak =
        length(Enum.uniq(digits)) == 1 or
          String.contains?("01234567890", pin) or String.contains?("09876543210", pin)

      if weak, do: [pin: "too easy to guess"], else: []
    end)
  end

  defp hash_pin(%{valid?: true, changes: %{pin: pin}} = cs),
    do: cs |> put_change(:pin_hash, Argon2.hash_pwd_salt(pin)) |> delete_change(:pin)

  defp hash_pin(cs), do: cs

  def pin_ok?(%__MODULE__{pin_hash: hash}, pin) when is_binary(pin) and is_binary(hash),
    do: Argon2.verify_pass(pin, hash)

  def pin_ok?(_, _), do: Argon2.no_user_verify() && false
end
