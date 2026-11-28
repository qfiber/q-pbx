defmodule QPBX.Web.Auth do
  @moduledoc """
  Portal sessions for platform admins and tenant users.

  A login is two steps when 2FA applies: the password puts a short-lived "pending" account in
  the cookie, and only a valid TOTP code starts a real session. Real sessions live in the
  database (`QPBX.Core.Sessions`): the cookie holds only a random token, every request and
  every LiveView event checks it, and revoking it disconnects the browser's live pages
  (their socket id is `sessions:<session id>`).
  """
  use QPBX.Web, :verified_routes
  use Gettext, backend: QPBX.Web.Gettext
  import Plug.Conn
  import Phoenix.Controller
  alias QPBX.Core
  alias QPBX.Core.{PlatformAdmin, User}
  alias QPBX.Web.Locale

  @pending_max_age 300

  ## Session lifecycle

  @doc "Password accepted: start a session, or hold the account pending its TOTP step."
  def after_password(conn, account) do
    conn = restart(conn, account)

    cond do
      Core.totp_enabled?(account) ->
        conn |> put_pending(account) |> redirect(to: ~p"/2fa")

      Core.requires_totp?(account) ->
        # Required but not enrolled yet (platform admins): enrol before any session.
        conn |> put_pending(account) |> redirect(to: ~p"/2fa/setup")

      true ->
        log_in(conn, account)
    end
  end

  @doc "Password just set through a setup link: go to 2FA enrolment."
  def start_enrolment(conn, account) do
    conn
    |> restart(account)
    |> put_pending(account)
    |> redirect(to: ~p"/2fa/setup")
  end

  def log_in(conn, account) do
    meta = %{ip: conn.remote_ip |> :inet.ntoa() |> to_string(), user_agent: user_agent(conn)}
    {token, session} = Core.create_session(account, meta)

    conn
    |> delete_session(:pending)
    |> configure_session(renew: true)
    |> put_session(:session_token, token)
    |> put_session(:live_socket_id, socket_id(session.id))
    |> redirect(to: home_path(account))
  end

  def log_out(conn) do
    if token = get_session(conn, :session_token), do: Core.end_session(token)
    locale = get_session(conn, :locale)
    conn |> renew_session() |> put_session(:locale, locale) |> redirect(to: ~p"/login")
  end

  @doc "Topic every LiveView of one session listens on; a broadcast there disconnects them."
  def socket_id(session_id), do: "sessions:" <> session_id

  defp user_agent(conn), do: conn |> get_req_header("user-agent") |> List.first()

  # New session id; keep a language chosen in this browser, else the account's or tenant's.
  defp restart(conn, account) do
    locale = get_session(conn, :locale) || account.locale || locale_of(account)
    conn |> renew_session() |> put_session(:locale, locale)
  end

  defp renew_session(conn), do: conn |> configure_session(renew: true) |> clear_session()

  defp put_pending(conn, account),
    do: put_session(conn, :pending, {kind(account), account.id, System.os_time(:second)})

  @doc "The account waiting for its TOTP step, if still fresh."
  def pending_account(conn) do
    with {kind, id, at} <- get_session(conn, :pending),
         true <- System.os_time(:second) - at <= @pending_max_age do
      load(kind, id)
    else
      _ -> nil
    end
  end

  ## Plugs and LiveView hooks

  def fetch_current_account(conn, _opts) do
    case Core.fetch_session(get_session(conn, :session_token)) do
      {:ok, account, session} ->
        conn
        |> assign(:current_account, account)
        |> assign(:current_session, session)
        |> assign(:current_scope, Core.scope_for(account))

      :error ->
        conn |> delete_session(:session_token) |> assign(:current_account, nil)
    end
  end

  def require_platform_admin(conn, _opts),
    do: require_kind(conn, PlatformAdmin, ~p"/platform/login")

  def require_tenant_user(conn, _opts), do: require_kind(conn, User, ~p"/login")

  defp require_kind(conn, struct, login_path) do
    case conn.assigns[:current_account] do
      %{__struct__: ^struct} -> conn
      _ -> conn |> redirect(to: login_path) |> halt()
    end
  end

  @check_every 30_000

  # :tenant_admin pages change the tenant's telephony configuration: tenant admins only.
  def on_mount(:tenant_admin, params, session, socket) do
    case on_mount(:tenant_user, params, session, socket) do
      {:cont, %{assigns: %{current_account: user}} = socket} ->
        if User.role(user) == "tenant_admin",
          do: {:cont, socket},
          else:
            {:halt,
             socket
             |> Phoenix.LiveView.put_flash(
               :error,
               gettext("Only tenant admins can open this page.")
             )
             |> Phoenix.LiveView.redirect(to: ~p"/app")}

      halt ->
        halt
    end
  end

  def on_mount(kind, _params, session, socket) when kind in [:platform_admin, :tenant_user] do
    locale = session["locale"] || Locale.default()
    Gettext.put_locale(QPBX.Web.Gettext, locale)
    expected = if kind == :platform_admin, do: PlatformAdmin, else: User
    token = session["session_token"]

    case Core.fetch_session(token) do
      {:ok, %{__struct__: ^expected} = account, current} ->
        if Phoenix.LiveView.connected?(socket),
          do: Process.send_after(self(), :check_session, @check_every)

        socket =
          socket
          |> Phoenix.Component.assign(
            current_account: account,
            current_session: current,
            current_scope: Core.scope_for(account),
            locale: locale
          )
          |> Phoenix.Component.assign(
            session_token: token,
            idle_timeout: Core.session_idle_timeout()
          )
          |> Phoenix.LiveView.attach_hook(:session_events, :handle_event, &check_on_event/3)
          |> Phoenix.LiveView.attach_hook(:session_timer, :handle_info, &check_on_timer/2)
          |> bell(account)

        {:cont, socket}

      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: login_path(kind))}
    end
  end

  # The notification bell: the unread count, kept current while the page is open.
  defp bell(socket, account) do
    if Phoenix.LiveView.connected?(socket),
      do: QPBX.Events.subscribe(QPBX.Events.NotificationsChanged)

    socket
    |> Phoenix.Component.assign(unread: QPBX.Notify.unread_count(account))
    |> Phoenix.LiveView.attach_hook(:bell, :handle_info, &bell_update/2)
  end

  defp bell_update({:event, %QPBX.Events.NotificationsChanged{account_id: id}}, socket) do
    if id == socket.assigns.current_account.id,
      do:
        {:halt,
         Phoenix.Component.assign(socket,
           unread: QPBX.Notify.unread_count(socket.assigns.current_account)
         )},
      else: {:halt, socket}
  end

  defp bell_update(_msg, socket), do: {:cont, socket}

  # Every user action re-checks the session (and counts as activity).
  defp check_on_event("keepalive", _params, socket) do
    case Core.fetch_session(socket.assigns.session_token) do
      {:ok, _, _} -> {:halt, socket}
      :error -> {:halt, expired(socket)}
    end
  end

  defp check_on_event(_event, _params, socket) do
    case Core.fetch_session(socket.assigns.session_token) do
      {:ok, _, _} -> {:cont, socket}
      :error -> {:halt, expired(socket)}
    end
  end

  # A periodic check catches revocations made where no broadcast reaches this node (the CLI).
  defp check_on_timer(:check_session, socket) do
    case Core.fetch_session(socket.assigns.session_token, touch: false) do
      {:ok, _, _} ->
        Process.send_after(self(), :check_session, @check_every)
        {:halt, socket}

      :error ->
        {:halt, expired(socket)}
    end
  end

  defp check_on_timer(_msg, socket), do: {:cont, socket}

  defp expired(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, gettext("Your session has ended. Please log in again."))
    |> Phoenix.LiveView.redirect(to: login_path(socket.assigns.current_account))
  end

  defp login_path(:platform_admin), do: ~p"/platform/login"
  defp login_path(%PlatformAdmin{}), do: ~p"/platform/login"
  defp login_path(_), do: ~p"/login"

  ## Helpers

  def home_path(%PlatformAdmin{}), do: ~p"/platform"
  def home_path(%User{}), do: ~p"/app"

  defp kind(%PlatformAdmin{}), do: "platform_admin"
  defp kind(%User{}), do: "user"
  defp load("platform_admin", id), do: Core.get_platform_admin(id)
  defp load("user", id), do: Core.get_user(id)

  defp locale_of(%User{tenant: %{locale: locale}}), do: locale
  defp locale_of(_), do: Locale.default()
end
