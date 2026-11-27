defmodule QPBX.Web.PageController do
  use QPBX.Web, :controller

  def home(conn, _params) do
    case conn.assigns.current_account do
      nil -> redirect(conn, to: ~p"/login")
      account -> redirect(conn, to: QPBX.Web.Auth.home_path(account))
    end
  end
end
