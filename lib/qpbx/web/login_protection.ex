defmodule QPBX.Web.LoginProtection do
  @moduledoc """
  Guards the login, 2FA and setup pages: blocked client IPs get HTTP 429 (limits in
  `QPBX.Core.LoginGuard`), forms carry the installation's human check (`QPBX.Web.Captcha`),
  and failures are counted. IPs on the platform allowlist for HTTPS are never blocked or
  challenged, so administrators can always get in.
  """
  @behaviour Plug
  use Gettext, backend: QPBX.Web.Gettext
  import Plug.Conn
  import Phoenix.Controller
  alias QPBX.Core
  alias QPBX.Web.Captcha

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = assign(conn, :login_exempt, QPBX.Firewall.allowlisted?(conn.remote_ip, "https"))

    case conn.assigns.login_exempt || Core.login_check(conn.remote_ip) do
      {:blocked, until} -> conn |> blocked(until) |> halt()
      _ -> conn
    end
  end

  @doc "Counts a failure. Returns the conn, or a 429 response (halted) when the IP is now blocked."
  def failed(conn, account \\ nil, kind \\ :password) do
    case !conn.assigns.login_exempt && Core.login_failed(conn.remote_ip, account, kind) do
      {:blocked, until} -> {:halt, conn |> blocked(until) |> halt()}
      _ -> {:cont, conn}
    end
  end

  def succeeded(conn) do
    unless conn.assigns.login_exempt, do: Core.login_succeeded(conn.remote_ip)
    conn
  end

  @doc "Whether the human check passed (always true for allowlisted IPs or provider `:none`)."
  def human?(conn, params),
    do: conn.assigns.login_exempt || Captcha.verify(params, conn.remote_ip) == :ok

  @doc "Assigns for rendering the check in a form."
  def captcha_assigns(conn) do
    challenge =
      if Captcha.provider() == :pow and !conn.assigns[:login_exempt],
        do: QPBX.Web.Captcha.Pow.challenge()

    [captcha?: !conn.assigns[:login_exempt], captcha_challenge: challenge]
  end

  defp blocked(conn, until) do
    conn
    |> put_status(429)
    |> put_view(QPBX.Web.AuthHTML)
    |> render(:blocked, until: until, page_title: gettext("Too many attempts"))
  end
end
