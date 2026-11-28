defmodule QPBX.Core.PlatformSettings do
  @moduledoc """
  The platform's settings changed in the portal (one row): outgoing email and the human check
  on the sign-in pages. A field left empty falls back to the installation's value (Ansible);
  passwords and secrets are encrypted and never shown again.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @captcha_providers ~w(pow turnstile friendly_captcha captcha_eu none)

  @primary_key {:id, :boolean, autogenerate: false}
  schema "platform_settings" do
    field :smtp_host, :string
    field :smtp_port, :integer
    field :smtp_username, :string
    field :smtp_password, QPBX.Core.Encrypted.Binary, redact: true
    field :mail_from, :string
    field :captcha_provider, :string
    field :captcha_site_key, :string
    field :captcha_secret, QPBX.Core.Encrypted.Binary, redact: true
    # Proof-of-work strength: the numbers a browser searches (empty: 60,000).
    field :pow_max_number, :integer
    timestamps(type: :utc_datetime)
  end

  def captcha_providers, do: @captcha_providers

  @doc """
  An empty password or secret keeps the stored one (they are never shown, so a form sends
  them empty); `nil` given on purpose clears it.
  """
  def changeset(settings, attrs) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> drop_blank_secrets()

    settings
    |> cast(attrs, ~w(smtp_host smtp_port smtp_username smtp_password mail_from
                      captcha_provider captcha_site_key captcha_secret pow_max_number)a,
      empty_values: [""]
    )
    |> update_change(:smtp_host, &(&1 && String.trim(&1)))
    |> validate_number(:smtp_port, greater_than: 0, less_than: 65_536)
    |> validate_format(:smtp_host, ~r/^[A-Za-z0-9.-]+$/)
    |> validate_format(:mail_from, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/)
    |> validate_inclusion(:captcha_provider, @captcha_providers)
    |> validate_length(:smtp_username, max: 200)
    |> validate_length(:captcha_site_key, max: 200)
    |> validate_number(:pow_max_number,
      greater_than_or_equal_to: 10_000,
      less_than_or_equal_to: 2_000_000
    )
    |> validate_service_keys()
  end

  # An outside service needs its site key and secret (saved now or before).
  defp validate_service_keys(cs) do
    if get_field(cs, :captcha_provider) in ~w(turnstile friendly_captcha captcha_eu) do
      cs
      |> then(
        &if get_field(&1, :captcha_site_key),
          do: &1,
          else: add_error(&1, :captcha_site_key, "can't be blank")
      )
      |> then(
        &if get_field(&1, :captcha_secret),
          do: &1,
          else: add_error(&1, :captcha_secret, "can't be blank")
      )
    else
      cs
    end
  end

  defp drop_blank_secrets(attrs) do
    Enum.reduce(~w(smtp_password captcha_secret), attrs, fn k, acc ->
      if acc[k] == "", do: Map.delete(acc, k), else: acc
    end)
  end
end
