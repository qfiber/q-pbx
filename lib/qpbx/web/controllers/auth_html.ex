defmodule QPBX.Web.AuthHTML do
  @moduledoc "Login, 2FA and account setup pages."
  use QPBX.Web, :html

  def login(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale}>
      <.header>
        {if @platform?, do: gettext("Platform admin login"), else: gettext("Log in")}
      </.header>
      <p :if={@error} class="alert alert-error" role="alert">{@error}</p>
      <.form for={@form} action={@action} id="login-form">
        <.input
          field={@form[:email]}
          type="email"
          label={gettext("Email")}
          autocomplete="username"
          required
        />
        <.input
          field={@form[:password]}
          type="password"
          label={gettext("Password")}
          autocomplete="current-password"
          required
        />
        <QPBX.Web.Captcha.widget :if={@captcha?} form="login-form" challenge={@captcha_challenge} />
        <.button variant="primary" class="w-full">{gettext("Log in")}</.button>
      </.form>
    </Layouts.app>
    """
  end

  def totp(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale}>
      <.header>
        {gettext("Two-factor authentication")}
        <:subtitle>{gettext("Enter the 6-digit code from your authenticator app.")}</:subtitle>
      </.header>
      <p :if={@error} class="alert alert-error" role="alert">{@error}</p>
      <.form for={@form} action={~p"/2fa"} id="totp-form">
        <.input
          field={@form[:code]}
          label={gettext("Code")}
          inputmode="numeric"
          autocomplete="one-time-code"
          pattern="[0-9 ]*"
          required
        />
        <.button variant="primary" class="w-full">{gettext("Verify")}</.button>
      </.form>
    </Layouts.app>
    """
  end

  def totp_setup(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale}>
      <.header>
        {gettext("Set up two-factor authentication")}
        <:subtitle>
          {gettext("Scan this code with an authenticator app, then enter the 6-digit code it shows.")}
        </:subtitle>
      </.header>
      <div class="flex flex-col items-center gap-2">
        <div class="bg-white p-2 rounded" aria-hidden="true">{Phoenix.HTML.raw(@qr_svg)}</div>
        <p class="text-sm">
          {gettext("Or enter this key by hand:")}
          <code class="font-mono" dir="ltr" id="totp-secret">{@secret}</code>
        </p>
      </div>
      <p :if={@error} class="alert alert-error" role="alert">{@error}</p>
      <.form for={@form} action={~p"/2fa/setup"} id="totp-setup-form">
        <.input
          field={@form[:code]}
          label={gettext("Code")}
          inputmode="numeric"
          autocomplete="one-time-code"
          required
        />
        <.button variant="primary" class="w-full">{gettext("Turn on 2FA")}</.button>
      </.form>
      <.form :if={@can_skip?} for={%{}} action={~p"/2fa/skip"} id="totp-skip-form">
        <.button class="btn btn-ghost w-full">{gettext("Not now")}</.button>
      </.form>
    </Layouts.app>
    """
  end

  def setup(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale}>
      <.header>
        {gettext("Set up your account")}
        <:subtitle><span dir="ltr">{@email}</span></:subtitle>
      </.header>
      <p :if={@error} class="alert alert-error" role="alert">{@error}</p>
      <.form for={@form} action={@action} method="put" id="setup-form">
        <.input
          field={@form[:password]}
          type="password"
          label={gettext("New password (at least 12 characters)")}
          autocomplete="new-password"
          required
        />
        <.input
          field={@form[:password_confirmation]}
          type="password"
          label={gettext("Repeat the password")}
          autocomplete="new-password"
          required
        />
        <QPBX.Web.Captcha.widget :if={@captcha?} form="setup-form" challenge={@captcha_challenge} />
        <.button variant="primary" class="w-full">{gettext("Save password")}</.button>
      </.form>
    </Layouts.app>
    """
  end

  def blocked(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale}>
      <.header>{gettext("Too many attempts")}</.header>
      <p class="alert alert-error" role="alert" id="blocked">
        {gettext("Too many failed attempts from your network. Try again after %{time} (UTC).",
          time: Calendar.strftime(@until, "%Y-%m-%d %H:%M")
        )}
      </p>
    </Layouts.app>
    """
  end
end
