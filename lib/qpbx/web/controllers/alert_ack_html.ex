defmodule QPBX.Web.AlertAckHTML do
  @moduledoc false
  use QPBX.Web, :html

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale}>
      <.header>{gettext("Acknowledge alert")}</.header>
      <p :if={@done} id="ack-done">
        {gettext(
          "Acknowledged: %{title}. Others are not told again about this alert until it changes.",
          title: @title
        )}
      </p>
      <p :if={!@done and is_nil(@link)} id="ack-invalid">{gettext("This link is not valid.")}</p>
      <.form :if={!@done and @link} for={%{}} action={~p"/alerts/ack/#{@link}"} id="ack-form">
        <p>{gettext("Acknowledge this alert so the others who got it know someone is on it.")}</p>
        <.button variant="primary" id="ack-button">{gettext("Acknowledge")}</.button>
      </.form>
    </Layouts.app>
    """
  end
end
