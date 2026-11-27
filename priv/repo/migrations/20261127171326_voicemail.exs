defmodule QPBX.Repo.Migrations.Voicemail do
  use Ecto.Migration
  alias QPBX.Repo.RLS

  def change do
    # One mailbox per extension (QPBX.Telephony.Voicemail). Without one, unanswered calls end.
    create table(:mailboxes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :extension_id, references(:extensions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :enabled, :boolean, null: false, default: true
      add :pin_hash, :string, null: false
      add :email, :string
      add :attach_audio, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:mailboxes, [:extension_id])
    create index(:mailboxes, [:tenant_id])
    RLS.enable("mailboxes")

    # Greetings: unavailable, busy, temporary (the temporary one wins while it exists).
    create table(:greetings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :file_key, :string, null: false
      add :format, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:greetings, [:mailbox_id, :kind])
    RLS.enable("greetings")

    create table(:voicemails, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :caller_number, :string
      add :caller_name, :string
      add :duration, :integer, null: false
      add :file_key, :string, null: false
      add :format, :string, null: false
      add :folder, :string, null: false, default: "new"
      timestamps(type: :utc_datetime)
    end

    create index(:voicemails, [:mailbox_id, :folder])
    create index(:voicemails, [:tenant_id])
    RLS.enable("voicemails")
  end
end
