defmodule QPBX.Web.TotpController do
  use QPBX.Web, :controller
  alias QPBX.Core
  alias QPBX.Web.Auth

  plug :put_view, QPBX.Web.AuthHTML
  plug QPBX.Web.LoginProtection
  plug :require_pending

  ## Login step

  def show(conn, _params), do: render_verify(conn, nil)

  def verify(conn, %{"totp" => %{"code" => code}}) do
    case Core.verify_totp(conn.assigns.pending, code) do
      {:ok, account} ->
        Auth.log_in(conn, account)

      {:error, _} ->
        code_failed(
          conn,
          &render_verify(&1, gettext("That code is not valid. Try the next one."))
        )
    end
  end

  defp render_verify(conn, error) do
    render(conn, :totp,
      form: Phoenix.Component.to_form(%{}, as: :totp),
      error: error,
      page_title: gettext("Two-factor authentication")
    )
  end

  ## Enrolment

  def setup(conn, _params) do
    secret = Core.new_totp_secret()

    conn
    |> put_session(:totp_secret, Base.encode32(secret, padding: false))
    |> render_setup(secret, nil)
  end

  def enable(conn, %{"totp" => %{"code" => code}}) do
    secret = conn |> get_session(:totp_secret) |> to_string() |> Base.decode32!(padding: false)

    case Core.enable_totp(conn.assigns.pending, secret, code) do
      {:ok, account} ->
        conn |> delete_session(:totp_secret) |> Auth.log_in(account)

      {:error, _} ->
        code_failed(
          conn,
          &render_setup(&1, secret, gettext("That code is not valid. Try the next one."))
        )
    end
  end

  @doc "Tenant users may skip enrolment; platform admins and tenant admins may not."
  def skip(conn, _params) do
    account = conn.assigns.pending

    if Core.totp_optional?(account),
      do: Auth.log_in(conn, account),
      else: redirect(conn, to: ~p"/2fa/setup")
  end

  defp render_setup(conn, secret, error) do
    account = conn.assigns.pending
    uri = Core.totp_uri(account, secret)

    render(conn, :totp_setup,
      form: Phoenix.Component.to_form(%{}, as: :totp),
      qr_svg: uri |> EQRCode.encode() |> EQRCode.svg(width: 220),
      secret: Base.encode32(secret, padding: false),
      can_skip?: Core.totp_optional?(account),
      error: error,
      page_title: gettext("Set up two-factor authentication")
    )
  end

  defp code_failed(conn, render) do
    case QPBX.Web.LoginProtection.failed(conn, conn.assigns.pending, :totp) do
      {:halt, conn} -> conn
      {:cont, conn} -> render.(conn)
    end
  end

  defp require_pending(conn, _opts) do
    case Auth.pending_account(conn) do
      nil ->
        conn
        |> put_flash(:error, gettext("Please log in again."))
        |> redirect(to: ~p"/login")
        |> halt()

      account ->
        assign(conn, :pending, account)
    end
  end
end
