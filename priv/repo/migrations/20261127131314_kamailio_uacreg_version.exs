defmodule QPBX.Repo.Migrations.KamailioUacregVersion do
  use Ecto.Migration

  # Kamailio 6.0 checks uacreg at version 5 (same columns as the view has).
  def up do
    execute """
    CREATE OR REPLACE VIEW kamailio.version AS
      SELECT * FROM (VALUES ('dispatcher', 4), ('uacreg', 5), ('address', 6)) v(table_name, table_version)
    """
  end

  def down, do: :ok
end
