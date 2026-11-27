defmodule QPBX.Web.SessionController do
  use QPBX.Web, :controller
  alias QPBX.Core
  alias QPBX.Web.{Auth, LoginProtection}

  plug :put_view, QPBX.Web.AuthHTML
  plug LoginProtection when action in [:new, :create]

  def new(conn, _params), do: render_login(conn, nil)

  def create(conn, %{"login" => %{"email" => email, "password" => password}} = params) do
    if LoginProtection.human?(conn, params) do
      case authenticate(audience(conn), email, password) do
        {:ok, account} ->
          conn |> LoginProtection.succeeded() |> Auth.after_password(account)

        :error ->
          fail(conn, Core.find_account_by_email(email), gettext("Wrong email or password."))
      end
    else
      fail(conn, nil, gettext("The automatic check did not pass. Please try again."))
    end
  end

  defp authenticate(:platform, email, password),
    do: Core.authenticate_platform_admin(email, password)

  defp authenticate(:tenant, email, password), do: Core.authenticate_user(email, password)

  defp fail(conn, account, message) do
    case LoginProtection.failed(conn, account) do
      {:halt, conn} -> conn
      {:cont, conn} -> render_login(conn, message)
    end
  end

  def delete(conn, _params), do: Auth.log_out(conn)

  defp render_login(conn, error) do
    platform? = audience(conn) == :platform
    action = if platform?, do: ~p"/platform/login", else: ~p"/login"

    render(
      conn,
      :login,
      [
        form: Phoenix.Component.to_form(%{"email" => ""}, as: :login),
        action: action,
        platform?: platform?,
        error: error,
        page_title: gettext("Log in")
      ] ++ LoginProtection.captcha_assigns(conn)
    )
  end

  defp audience(conn),
    do: if(conn.path_info == ["platform", "login"], do: :platform, else: :tenant)
end
