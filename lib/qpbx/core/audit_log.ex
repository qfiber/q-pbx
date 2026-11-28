defmodule QPBX.Core.AuditLog do
  @moduledoc "One audited change: who did what to which object."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_logs" do
    field :tenant_id, :binary_id
    field :actor_type, :string
    field :actor_id, :binary_id
    field :action, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :changes, :map, default: %{}
    # Names at the time of the change (the records may be removed later).
    field :actor_label, :string
    field :target_label, :string
    field :tenant_label, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
