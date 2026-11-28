defmodule QPBX.Repo.Migrations.AuditLabels do
  @moduledoc """
  Names kept with each audit entry when it is written (who did it, what it was done to, which
  tenant), so the log stays readable after an account, a record or a tenant is removed.
  """
  use Ecto.Migration

  def change do
    alter table(:audit_logs) do
      add :actor_label, :string
      add :target_label, :string
      add :tenant_label, :string
    end
  end
end
