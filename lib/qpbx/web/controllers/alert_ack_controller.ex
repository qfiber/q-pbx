defmodule QPBX.Web.AlertAckController do
  @moduledoc """
  The acknowledge link in alert emails (`/alerts/ack/<notification id>.<token>`). Opening it
  shows a button; acknowledging takes a click (a POST), because mail scanners open links on
  their own. No login: the token, sent only in that email, is the permission.
  """
  use QPBX.Web, :controller

  def show(conn, %{"link" => link}),
    do: render(conn, :show, link: link, done: false, page_title: gettext("Acknowledge alert"))

  def confirm(conn, %{"link" => link}) do
    case QPBX.Notify.acknowledge_by_token(link) do
      {:ok, alert} ->
        render(conn, :show,
          link: link,
          done: true,
          title: alert.title,
          page_title: gettext("Acknowledge alert")
        )

      {:error, _} ->
        conn
        |> put_status(404)
        |> render(:show, link: nil, done: false, page_title: gettext("Acknowledge alert"))
    end
  end
end
