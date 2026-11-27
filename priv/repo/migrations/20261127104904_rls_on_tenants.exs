defmodule QPBX.Repo.Migrations.RlsOnTenants do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  # Inside a tenant scope, a tenant sees only its own row.
  def change, do: RLS.enable("tenants", "id")
end
