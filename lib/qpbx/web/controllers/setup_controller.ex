defmodule QPBX.Web.SetupController do
  @moduledoc "One-time account setup links: choose a password, then 2FA."
  use QPBX.Web, :controller
  alias QPBX.Core
  alias QPBX.Web.Auth

  alias QPBX.Web.LoginProtection

  plug :put_view, QPBX.Web.AuthHTML
  plug LoginProtection

  def show(conn, %{"token" => token}) do
    case Core.account_from_setup_token(token) do
      {:ok, account} -> render_form(conn, token, Core.change_password(account))
      :error -> invalid(conn)
    end
  end

  def update(conn, %{"token" => token, "account" => attrs} = params) do
    with {:ok, account} <- Core.account_from_setup_token(token),
         {:human, true, _} <- {:human, LoginProtection.human?(conn, params), account},
         {:ok, account} <- Core.complete_setup(account, attrs) do
      # Straight on to 2FA enrolment, which tenant users may skip.
      conn |> LoginProtection.succeeded() |> Auth.start_enrolment(account)
    else
      :error ->
        invalid(conn)

      {:human, false, account} ->
        case LoginProtection.failed(conn, account) do
          {:halt, conn} ->
            conn

          {:cont, conn} ->
            render_form(
              conn,
              token,
              Core.change_password(account),
              gettext("The automatic check did not pass. Please try again.")
            )
        end

      {:error, cs} ->
        render_form(conn, token, cs)
    end
  end

  defp render_form(conn, token, cs, error \\ nil) do
    render(
      conn,
      :setup,
      [
        form: Phoenix.Component.to_form(cs, as: :account),
        action: ~p"/setup/#{token}",
        email: cs.data.email,
        error: error,
        page_title: gettext("Set up your account")
      ] ++ LoginProtection.captcha_assigns(conn)
    )
  end

  # A bad or expired setup link counts as a failed attempt (link guessing).
  defp invalid(conn) do
    case LoginProtection.failed(conn) do
      {:halt, conn} -> conn
      {:cont, conn} -> invalid_redirect(conn)
    end
  end

  defp invalid_redirect(conn) do
    conn
    |> put_flash(
      :error,
      gettext("This setup link is invalid or has expired. Ask your administrator for a new one.")
    )
    |> redirect(to: ~p"/login")
  end
end
