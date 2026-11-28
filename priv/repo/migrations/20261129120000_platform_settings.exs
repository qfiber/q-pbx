defmodule QPBX.Repo.Migrations.PlatformSettings do
  @moduledoc """
  The platform's own settings changed in the portal: outgoing email (SMTP) and the human check
  on the sign-in pages. One row; an empty value falls back to the installation's (Ansible).
  """
  use Ecto.Migration

  def up do
    create table(:platform_settings, primary_key: false) do
      add :id, :boolean, primary_key: true, default: true
      add :smtp_host, :string
      add :smtp_port, :integer
      add :smtp_username, :string
      add :smtp_password, :binary
      add :mail_from, :string
      add :captcha_provider, :string
      add :captcha_site_key, :string
      add :captcha_secret, :binary
      timestamps(type: :utc_datetime)
    end

    execute "INSERT INTO platform_settings (id, inserted_at, updated_at) VALUES (true, now(), now())"
  end

  def down, do: drop(table(:platform_settings))
end
