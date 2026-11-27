defmodule QPBX.Web.SessionController do
  use QPBX.Web, :controller
  alias QPBX.Core
  alias QPBX.Web.Auth

  plug :put_view, QPBX.Web.AuthHTML

  def new(conn, _params), do: render_login(conn, nil)

  def create(conn, %{"login" => %{"email" => email, "password" => password}}) do
    result =
      case audience(conn) do
        :platform -> Core.authenticate_platform_admin(email, password)
        :tenant -> Core.authenticate_user(email, password)
      end

    case result do
      {:ok, account} -> Auth.after_password(conn, account)
      :error -> render_login(conn, gettext("Wrong email or password."))
    end
  end

  def delete(conn, _params), do: Auth.log_out(conn)

  defp render_login(conn, error) do
    platform? = audience(conn) == :platform
    action = if platform?, do: ~p"/platform/login", else: ~p"/login"

    render(conn, :login,
      form: Phoenix.Component.to_form(%{"email" => ""}, as: :login),
      action: action,
      platform?: platform?,
      error: error,
      page_title: gettext("Log in")
    )
  end

  defp audience(conn),
    do: if(conn.path_info == ["platform", "login"], do: :platform, else: :tenant)
end
