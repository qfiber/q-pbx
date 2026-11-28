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
      <.live_component module={PagedTable} id="sessions" rows={@sessions}>
        <:col :let={s} label={gettext("Browser")}>
          <div class="flex items-center gap-3">
            <span class="size-8 shrink-0 rounded-[8px] grid place-items-center bg-accent-pale text-secondary">
              <.icon name="hero-computer-desktop" class="size-4" />
            </span>
            <div class="min-w-0">
              <span dir="ltr" class="block text-xs truncate max-w-md">{s.user_agent}</span>
              <span class="text-xs text-muted" dir="ltr">{s.ip}</span>
            </div>
          </div>
        </:col>
        <:col :let={s} label={gettext("Signed in")}>
          <span class="text-sm">{s.inserted_at}</span>
        </:col>
        <:col :let={s} label={gettext("Last active")}>
          <span class="text-sm">{s.last_seen_at}</span>
        </:col>
        <:action :let={s}>
          <.chip :if={s.id == @current_session.id} tone={:ok}>{gettext("This browser")}</.chip>
          <.link
            :if={s.id != @current_session.id}
            phx-click="revoke"
            phx-value-id={s.id}
            id={"revoke-#{s.id}"}
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4 rtl:rotate-180" />
            {gettext("Sign out")}
          </.link>
        </:action>
      </.live_component>
    </Layouts.app>
    """
  end
end
