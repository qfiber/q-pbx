defmodule QPBX.Core.Device do
  @moduledoc """
  A phone, softphone, ATA or mobile app on an extension. Each device has its own SIP login
  (`<extension>-<label>`), so one lost phone can be cut off without touching the others.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(desk_phone softphone ata mobile)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "devices" do
    field :tenant_id, :binary_id
    field :label, :string
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

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:label, :kind, :mac, :model])
    |> validate_required([:label, :kind])
    |> validate_format(:label, ~r/\A[a-z0-9]{1,16}\z/,
      message: "lowercase letters and digits, up to 16"
    )
    |> validate_inclusion(:kind, @kinds)
    |> update_change(:mac, &(&1 |> String.downcase() |> String.replace(~r/[^0-9a-f]/, "")))
    |> validate_format(:mac, ~r/\A[0-9a-f]{12}\z/, message: "12 hex digits")
    |> validate_length(:model, max: 100)
    |> unique_constraint(:mac)
  end
end
