defmodule QPBX.Core.UserRole do
  @moduledoc "The user's role in their tenant."
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(tenant_admin tenant_user)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_roles" do
    field :role, :string
    belongs_to :tenant, QPBX.Core.Tenant
    belongs_to :user, QPBX.Core.User
    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
  end
end
