defmodule QPBX.Repo.Migrations.CreateFirewallEntries do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    create table(:firewall_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :level, :string, null: false
      # NULL for platform entries.
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :kind, :string, null: false
      add :scope, :string, null: false
      add :cidr, :string, null: false
      add :family, :string, null: false
      add :expires_at, :utc_datetime
      add :reason, :string, null: false
      add :author_type, :string, null: false
      add :author_id, :binary_id
      timestamps(type: :utc_datetime)
    end

    create unique_index(:firewall_entries, [:level, :tenant_id, :kind, :scope, :cidr],
             name: :firewall_entries_unique,
             nulls_distinct: false
           )

    create index(:firewall_entries, [:tenant_id])

    create constraint(:firewall_entries, :level_matches_tenant,
             check:
               "(level = 'platform' AND tenant_id IS NULL) OR (level = 'tenant' AND tenant_id IS NOT NULL)"
           )

    RLS.enable("firewall_entries")
  end
end
