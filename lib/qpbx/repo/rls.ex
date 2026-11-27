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

  # NULLIF before the cast: Postgres may evaluate both sides of OR, and after a scoped
  # transaction the setting is '' on that connection, which is not a valid uuid.
  @setting "NULLIF(current_setting('app.tenant_id', true), '')"
  @check "#{@setting} IS NULL OR tenant_id = #{@setting}::uuid"

  def check, do: @check

  @doc "Enables the policy on `table`, matching the tenant on `column` (`id` for `tenants`)."
  def enable(table, column \\ "tenant_id") do
    check = String.replace(@check, "tenant_id =", "#{column} =")

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
