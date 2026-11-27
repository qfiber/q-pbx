defmodule QPBX.Repo.Migrations.UserExtension do
  use Ecto.Migration

  def change do
    # A tenant user's own extension (voicemail, calls, forwarding); at most one user each.
    alter table(:users) do
      add :extension_id, references(:extensions, type: :binary_id, on_delete: :nilify_all)
    end

    create unique_index(:users, [:extension_id])
  end
end
