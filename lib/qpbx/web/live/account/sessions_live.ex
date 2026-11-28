defmodule QPBX.Web.Account.SessionsLive do
  @moduledoc "The signed-in account's sessions: see where you are signed in, end any of them."
  use QPBX.Web, :live_view
  alias QPBX.Core

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: gettext("Your sessions")) |> load()}
  end

  defp load(socket),
    do: assign(socket, sessions: Core.list_my_sessions(socket.assigns.current_scope))

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    account = socket.assigns.current_account
    {:ok, _} = Core.revoke_session(account, id, account)
    {:noreply, socket |> put_flash(:info, gettext("Session ended.")) |> load()}
  end

  def handle_event("revoke_others", _params, socket) do
    account = socket.assigns.current_account
    {:ok, n} = Core.revoke_sessions(account, account, except: socket.assigns.current_session.id)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Signed out of %{count} other sessions.", count: n))
     |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      locale={@locale}
      current_account={@current_account}
      unread={assigns[:unread]}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("Your sessions")}
        <:subtitle>
          {gettext("Sessions end after %{minutes} minutes without activity and 12 hours after login.",
            minutes: div(@idle_timeout, 60)
          )}
        </:subtitle>
        <:actions>
          <.button phx-click="revoke_others" id="revoke-others">
            {gettext("Sign out everywhere else")}
          </.button>
        </:actions>
      </.header>
      <.table id="sessions" rows={@sessions}>
        <:col :let={s} label={gettext("Signed in")}>{s.inserted_at}</:col>
        <:col :let={s} label={gettext("Last active")}>{s.last_seen_at}</:col>
        <:col :let={s} label={gettext("Address")}><span dir="ltr">{s.ip}</span></:col>
        <:col :let={s} label={gettext("Browser")}>
          <span dir="ltr" class="text-xs">{s.user_agent}</span>
        </:col>
        <:action :let={s}>
          <span :if={s.id == @current_session.id} class="badge">{gettext("This browser")}</span>
          <.link
            :if={s.id != @current_session.id}
            phx-click="revoke"
            phx-value-id={s.id}
            id={"revoke-#{s.id}"}
          >
            {gettext("Sign out")}
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end
end
