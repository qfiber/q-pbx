defmodule QPBX.Web.SetupController do
  @moduledoc "One-time account setup links: choose a password, then 2FA."
  use QPBX.Web, :controller
  alias QPBX.Core
  alias QPBX.Web.Auth

  plug :put_view, QPBX.Web.AuthHTML

  def show(conn, %{"token" => token}) do
    case Core.account_from_setup_token(token) do
      {:ok, account} -> render_form(conn, token, Core.change_password(account))
      :error -> invalid(conn)
    end
  end

  def update(conn, %{"token" => token, "account" => attrs}) do
    with {:ok, account} <- Core.account_from_setup_token(token),
         {:ok, account} <- Core.complete_setup(account, attrs) do
      # Straight on to 2FA enrolment, which tenant users may skip.
      Auth.start_enrolment(conn, account)
    else
      :error -> invalid(conn)
      {:error, cs} -> render_form(conn, token, cs)
    end
  end

  defp render_form(conn, token, cs) do
    render(conn, :setup,
      form: Phoenix.Component.to_form(cs, as: :account),
      action: ~p"/setup/#{token}",
      email: cs.data.email,
      page_title: gettext("Set up your account")
    )
  end

  defp invalid(conn) do
    conn
    |> put_flash(
      :error,
      gettext("This setup link is invalid or has expired. Ask your administrator for a new one.")
    )
    |> redirect(to: ~p"/login")
  end
end
