defmodule QPBX.Repo.Migrations.PowStrength do
  @moduledoc "How hard the built-in proof of work is: the range of numbers a browser searches."
  use Ecto.Migration

  def change do
    alter table(:platform_settings) do
      add :pow_max_number, :integer
    end
  end
end
