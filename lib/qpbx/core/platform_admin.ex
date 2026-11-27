defmodule QPBX.Core.PlatformAdmin do
  @moduledoc "A platform admin: manages all tenants. 2FA is mandatory."
  use Ecto.Schema
  import Ecto.Changeset
  require QPBX.Core.Credentials
  alias QPBX.Core.Credentials

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "platform_admins" do
    Credentials.fields()
    timestamps(type: :utc_datetime)
  end

  def changeset(admin, attrs) do
    admin
    |> cast(attrs, [:email, :name, :locale])
    |> Credentials.profile_changeset()
  end
end
