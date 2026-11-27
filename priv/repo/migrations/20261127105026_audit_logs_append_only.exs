defmodule QPBX.Repo.Migrations.AuditLogsAppendOnly do
  use Ecto.Migration

  # In production migrations run as the schema owner and the app connects as a separate role
  # (QPBX_DB_APP_ROLE). That role may add audit entries and read them, never change or remove
  # them. Development and tests use one role, so nothing happens there.
  def up do
    if role = app_role(),
      do: execute("REVOKE UPDATE, DELETE, TRUNCATE ON audit_logs FROM #{role}")
  end

  def down do
    if role = app_role(), do: execute("GRANT UPDATE, DELETE, TRUNCATE ON audit_logs TO #{role}")
  end

  defp app_role do
    case System.get_env("QPBX_DB_APP_ROLE") do
      nil ->
        nil

      role ->
        if Regex.match?(~r/\A[a-z_][a-z0-9_]{0,62}\z/, role),
          do: role,
          else: raise("bad QPBX_DB_APP_ROLE")
    end
  end
end
