defmodule QPBX.Core.User do
  @moduledoc "A tenant user (tenant admin or tenant user). Belongs to exactly one tenant."
  use Ecto.Schema
  import Ecto.Changeset
  require QPBX.Core.Credentials
  alias QPBX.Core.{Credentials, Tenant, UserRole}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    Credentials.fields()
    belongs_to :tenant, Tenant
    # The user's own extension (nil: none yet); set by a tenant admin.
    field :extension_id, :binary_id
    has_one :user_role, UserRole
    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :locale])
    |> Credentials.profile_changeset()
  end

  def role(%__MODULE__{user_role: %UserRole{role: role}}), do: role
end
