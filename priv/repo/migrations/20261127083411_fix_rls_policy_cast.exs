defmodule QPBX.Repo.Migrations.FixRlsPolicyCast do
  use Ecto.Migration

  # The first policy version could cast '' to uuid; recreate it with QPBX.Repo.RLS.check/0.
  @tables ~w(users user_roles audit_logs firewall_entries)
  @old "coalesce(current_setting('app.tenant_id', true), '') = '' OR tenant_id = current_setting('app.tenant_id', true)::uuid"

  def up, do: Enum.each(@tables, &recreate(&1, QPBX.Repo.RLS.check()))
  def down, do: Enum.each(@tables, &recreate(&1, @old))

  defp recreate(table, check) do
    execute "DROP POLICY tenant_isolation ON #{table}"
    execute "CREATE POLICY tenant_isolation ON #{table} USING (#{check}) WITH CHECK (#{check})"
  end
end
