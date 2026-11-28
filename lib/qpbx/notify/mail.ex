defmodule QPBX.Notify.Mail do
  @moduledoc """
  Sends every email of the notify area with the platform's settings: the SMTP server and the
  sender address saved in the portal (`QPBX.Core.platform_settings/0`), each falling back to
  the installation's (`config :qpbx, QPBX.Notify.Mailer` and `:mail_from`). Read at each send,
  so a change applies to the next email.
  """
  alias QPBX.Notify.Mailer

  @doc "Delivers `email` through the configured SMTP server."
  def deliver(email), do: Mailer.deliver(email, smtp(QPBX.Core.platform_settings()))

  @doc "The installation's email settings (Ansible), shown as what an empty field falls back to."
  def installation do
    c = Application.get_env(:qpbx, Mailer, [])

    from =
      case Application.get_env(:qpbx, :mail_from) do
        {_, address} -> address
        address -> address
      end

    %{host: c[:relay], port: c[:port], username: c[:username], from: from}
  end

  @doc "The sender: the portal's address, else the installation's."
  def sender do
    case QPBX.Core.platform_settings().mail_from do
      nil -> Application.get_env(:qpbx, :mail_from, {"Q-PBX", "noreply@localhost"})
      address -> {"Q-PBX", address}
    end
  end

  @doc """
  The mailer options the portal's settings change (none when its server is not set). With a
  login, TLS is required so credentials never cross the network in clear.
  """
  def smtp(%{smtp_host: nil}), do: []

  def smtp(s) do
    login =
      case s.smtp_username do
        # Swoosh refuses a nil login; empty strings with auth: :never send none (and replace
        # an installation login, which belongs to the installation's server).
        nil -> [auth: :never, tls: :if_available, username: "", password: ""]
        user -> [auth: :always, tls: :always, username: user, password: s.smtp_password]
      end

    [relay: s.smtp_host, port: s.smtp_port || 587] ++ login
  end
end
