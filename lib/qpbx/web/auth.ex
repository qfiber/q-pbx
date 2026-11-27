defmodule QPBX.Web.Auth do
  @moduledoc """
  Portal sessions for platform admins and tenant users.

  A login is two steps when 2FA applies: the password puts a short-lived "pending" account in
  the session, and only a valid TOTP code turns it into a real session. Sessions expire a fixed
  time after login (`:session_max_age`, default 12 h).
  """
  use QPBX.Web, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  alias QPBX.Core
  alias QPBX.Core.{PlatformAdmin, User}

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
    conn
    |> delete_session(:pending)
    |> configure_session(renew: true)
    |> put_session(:account, {kind(account), account.id, System.os_time(:second)})
    |> redirect(to: home_path(account))
  end

  def log_out(conn) do
    locale = get_session(conn, :locale)
    conn |> renew_session() |> put_session(:locale, locale) |> redirect(to: ~p"/login")
  end

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
    assign(conn, :current_account, session_account(get_session(conn)))
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

  def on_mount(kind, _params, session, socket) when kind in [:platform_admin, :tenant_user] do
    Gettext.put_locale(QPBX.Web.Gettext, session["locale"] || "en")
    account = session_account(session)
    expected = if kind == :platform_admin, do: PlatformAdmin, else: User

    case account do
      %{__struct__: ^expected} ->
        {:cont,
         Phoenix.Component.assign(socket,
           current_account: account,
           locale: session["locale"] || "en"
         )}

      _ ->
        login = if kind == :platform_admin, do: ~p"/platform/login", else: ~p"/login"
        {:halt, Phoenix.LiveView.redirect(socket, to: login)}
    end
  end

  defp session_account(%{"account" => {kind, id, at}}) do
    if System.os_time(:second) - at <= max_age(), do: load(kind, id)
  end

  defp session_account(_), do: nil

  ## Helpers

  def home_path(%PlatformAdmin{}), do: ~p"/platform"
  def home_path(%User{}), do: ~p"/app"

  defp kind(%PlatformAdmin{}), do: "platform_admin"
  defp kind(%User{}), do: "user"
  defp load("platform_admin", id), do: Core.get_platform_admin(id)
  defp load("user", id), do: Core.get_user(id)

  defp locale_of(%User{tenant: %{locale: locale}}), do: locale
  defp locale_of(_), do: "en"

  defp max_age, do: Application.get_env(:qpbx, :session_max_age, 12 * 3600)
end
