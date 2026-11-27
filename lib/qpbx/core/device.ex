defmodule QPBX.Core.Device do
  @moduledoc """
  A phone, softphone, ATA or mobile app on an extension. Each device has its own SIP login
  (`<extension>-<label>`), so one lost phone can be cut off without touching the others. One
  device per extension may have no label: it logs in as the extension number itself, as most
  phones and softphones expect.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(desk_phone softphone ata mobile)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "devices" do
    field :tenant_id, :binary_id
    # Empty: the device logs in as the extension number itself (one such device per extension).
    field :label, :string, default: ""
    field :kind, :string
    field :mac, :string
    field :model, :string
    field :push_platform, :string
    field :push_token, QPBX.Core.Encrypted.Binary, redact: true
    belongs_to :extension, QPBX.Core.Extension
    belongs_to :sip_credential, QPBX.Core.SipCredential
    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc "The SIP login of a device on extension `number` with `label`."
  def username(number, ""), do: number
  def username(number, label), do: "#{number}-#{label}"

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:label, :kind, :mac, :model])
    # Cast turns "" into nil; an empty label is meaningful here (login = extension number).
    |> then(&if(is_nil(get_field(&1, :label)), do: put_change(&1, :label, ""), else: &1))
    |> validate_required([:kind])
    |> validate_format(:label, ~r/\A[a-z0-9]{0,16}\z/,
      message: "lowercase letters and digits, up to 16"
    )
    |> validate_inclusion(:kind, @kinds)
    |> update_change(:mac, &(&1 |> String.downcase() |> String.replace(~r/[^0-9a-f]/, "")))
    |> validate_format(:mac, ~r/\A[0-9a-f]{12}\z/, message: "12 hex digits")
    |> validate_length(:model, max: 100)
    |> unique_constraint(:mac)
  end
end
