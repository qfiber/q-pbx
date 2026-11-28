defmodule QPBX.Repo.Migrations.Prompts do
  @moduledoc "A tenant's prompt library: recordings played by IVRs, ring groups and the like."
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    create table(:prompts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :file_key, :string, null: false
      add :format, :string, null: false
      add :size, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:prompts, [:tenant_id, :name])
    RLS.enable("prompts")
  end
end
