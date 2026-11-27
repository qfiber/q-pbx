defmodule QPBX.Repo.RLS do
  @moduledoc """
  Row-level security as a safety net for tenant tables.

  Inside `QPBX.Core.with_tenant/2` the transaction sets `app.tenant_id`, and the policy hides
  every row of another tenant. Outside it (platform admin, background jobs) the setting is
  empty and the policy allows all rows; tenant scoping then comes from the queries themselves.
  FORCE makes the policy apply to the table owner too. Superusers still bypass it, so the app
  must never connect as one.
  """
  import Ecto.Migration

  @setting "current_setting('app.tenant_id', true)"

  def enable(table) do
    check = "coalesce(#{@setting}, '') = '' OR tenant_id = #{@setting}::uuid"

    execute(
      "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY",
      "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      "CREATE POLICY tenant_isolation ON #{table} USING (#{check}) WITH CHECK (#{check})",
      "DROP POLICY tenant_isolation ON #{table}"
    )
  end
end
