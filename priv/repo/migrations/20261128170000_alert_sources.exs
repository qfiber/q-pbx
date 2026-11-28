defmodule QPBX.Repo.Migrations.AlertSources do
  use Ecto.Migration

  def change do
    # Usage threshold alerts: percentages of a limit, per plan, overridable per tenant (NULL:
    # the plan's).
    alter table(:plans) do
      add :usage_thresholds, {:array, :integer}, null: false, default: [50, 80, 90, 100]
    end

    alter table(:tenants) do
      add :usage_thresholds, {:array, :integer}
    end

    # The addresses an account last logged in from (a login from another one is an alert).
    for t <- [:users, :platform_admins] do
      alter table(t) do
        add :login_ips, {:array, :string}, null: false, default: []
      end
    end
  end
end
