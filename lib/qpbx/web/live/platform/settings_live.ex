defmodule QPBX.Web.Platform.SettingsLive do
  @moduledoc """
  Platform admin: the server's settings that used to need Ansible. Outgoing email (SMTP server,
  login, sender) with a test email, and the human check on the sign-in pages. An empty field
  uses the installation's value (shown as its hint); passwords and secrets are never shown,
  and an empty one keeps what is saved. Changes apply at once.
  """
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Core.PlatformSettings

  @email_fields ~w(smtp_host smtp_port smtp_username smtp_password mail_from)
  @captcha_fields ~w(captcha_provider captcha_site_key captcha_secret)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Settings"),
       installation: QPBX.Notify.installation_email(),
       captcha_default: Application.get_env(:qpbx, QPBX.Web.Captcha, [])[:provider] || :pow,
       test_to: socket.assigns.current_account.email,
       test_result: nil
     )
     |> load()}
  end

  defp load(socket) do
    s = Core.platform_settings()

    assign(socket,
      settings: s,
      email_form: to_form(Core.change_platform_settings(s), as: :email),
      captcha_form: to_form(Core.change_platform_settings(s), as: :captcha)
    )
  end

  @impl true
  def handle_event("validate_email", %{"email" => p}, socket),
    do: {:noreply, assign(socket, email_form: form(socket, p, @email_fields, :email))}

  def handle_event("validate_captcha", %{"captcha" => p}, socket),
    do: {:noreply, assign(socket, captcha_form: form(socket, p, @captcha_fields, :captcha))}

  def handle_event("save_email", %{"email" => p}, socket),
    do: save(socket, Map.take(p, @email_fields), :email_form, :email)

  def handle_event("save_captcha", %{"captcha" => p}, socket),
    do: save(socket, Map.take(p, @captcha_fields), :captcha_form, :captcha)

  def handle_event("reset_email", _, socket),
    do: save(socket, Map.new(@email_fields, &{&1, nil}), :email_form, :email)

  def handle_event("reset_captcha", _, socket),
    do: save(socket, Map.new(@captcha_fields, &{&1, nil}), :captcha_form, :captcha)

  def handle_event("test_email", %{"test" => %{"to" => to}}, socket) do
    result = QPBX.Notify.send_test_email(String.trim(to), socket.assigns.locale)
    {:noreply, assign(socket, test_to: to, test_result: result)}
  end

  defp form(socket, params, fields, as) do
    socket.assigns.settings
    |> Core.change_platform_settings(Map.take(params, fields))
    |> Map.put(:action, :validate)
    |> to_form(as: as)
  end

  defp save(socket, attrs, form_key, as) do
    case Core.update_platform_settings(attrs, socket.assigns.current_account) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Saved. It applies at once.")) |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, [{form_key, to_form(Map.put(cs, :action, :update), as: as)}])}
    end
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
        {gettext("Settings")}
        <:subtitle>
          {gettext(
            "Server-wide settings. An empty field uses the installation's value, shown as its hint. Changes apply at once."
          )}
        </:subtitle>
      </.header>

      <.form for={@email_form} id="email-form" phx-change="validate_email" phx-submit="save_email">
        <.section
          title={gettext("Outgoing email")}
          icon="hero-envelope"
          hint={
            gettext(
              "The mail server every email goes through: alerts, voicemail, setup links. With a login, the connection must be encrypted (TLS)."
            )
          }
        >
          <div class="grid sm:grid-cols-[2fr_1fr] gap-x-4">
            <.input
              field={@email_form[:smtp_host]}
              label={gettext("Mail server")}
              placeholder={@installation.host}
              dir="ltr"
            />
            <.input
              field={@email_form[:smtp_port]}
              type="number"
              label={gettext("Port")}
              placeholder={@installation.port && to_string(@installation.port)}
            />
            <.input
              field={@email_form[:smtp_username]}
              label={gettext("Login (empty: none)")}
              placeholder={@installation.username}
              autocomplete="off"
              dir="ltr"
            />
            <.input
              field={@email_form[:smtp_password]}
              type="password"
              value=""
              label={
                if @settings.smtp_password,
                  do: gettext("Password (saved; empty keeps it)"),
                  else: gettext("Password")
              }
              autocomplete="new-password"
              dir="ltr"
            />
          </div>
          <div class="max-w-md">
            <.input
              field={@email_form[:mail_from]}
              type="email"
              label={gettext("Sender address")}
              placeholder={@installation.from}
              dir="ltr"
            />
          </div>
        </.section>
        <.form_actions>
          <.button variant="primary" id="save-email">{gettext("Save")}</.button>
          <.button
            type="button"
            phx-click="reset_email"
            id="reset-email"
            class="btn btn-ghost"
            data-confirm={gettext("Go back to the installation's email settings?")}
          >
            {gettext("Use the installation's settings")}
          </.button>
        </.form_actions>
      </.form>

      <form id="test-email-form" phx-submit="test_email" class="flex flex-wrap items-end gap-3">
        <label class="block grow min-w-60">
          <span class="text-sm">{gettext("Send a test email to")}</span>
          <input
            type="email"
            name="test[to]"
            value={@test_to}
            class="input w-full"
            dir="ltr"
            required
          />
        </label>
        <.button id="send-test-email" phx-disable-with={gettext("Sending...")}>
          <.icon name="hero-paper-airplane" class="size-4" /> {gettext("Send test email")}
        </.button>
        <p :if={@test_result == :ok} id="test-email-ok" class="w-full text-sm text-success">
          <.icon name="hero-check-circle" class="size-4" />
          {gettext("Sent. Check the inbox of %{to}.", to: @test_to)}
        </p>
        <p
          :if={match?({:error, _}, @test_result)}
          id="test-email-error"
          class="w-full text-sm text-error"
        >
          <.icon name="hero-exclamation-triangle" class="size-4" />
          {gettext("Not sent: %{reason}", reason: elem(@test_result, 1))}
        </p>
      </form>

      <.form
        for={@captcha_form}
        id="captcha-form"
        phx-change="validate_captcha"
        phx-submit="save_captcha"
      >
        <.section
          title={gettext("Sign-in protection")}
          icon="hero-shield-check"
          hint={
            gettext(
              "The human check on the login and account setup pages. Proof of work runs in the browser with no outside service."
            )
          }
        >
          <div class="max-w-md">
            <.input
              field={@captcha_form[:captcha_provider]}
              type="select"
              label={gettext("Check")}
              prompt={gettext("The installation's (%{name})", name: provider_label(@captcha_default))}
              options={Enum.map(PlatformSettings.captcha_providers(), &{provider_label(&1), &1})}
            />
          </div>
          <div class="grid sm:grid-cols-2 gap-x-4">
            <.input
              field={@captcha_form[:captcha_site_key]}
              label={gettext("Site key (outside services)")}
              dir="ltr"
            />
            <.input
              field={@captcha_form[:captcha_secret]}
              type="password"
              value=""
              label={
                if @settings.captcha_secret,
                  do: gettext("Secret (saved; empty keeps it)"),
                  else: gettext("Secret (outside services)")
              }
              autocomplete="new-password"
              dir="ltr"
            />
          </div>
        </.section>
        <.form_actions>
          <.button variant="primary" id="save-captcha">{gettext("Save")}</.button>
          <.button
            type="button"
            phx-click="reset_captcha"
            id="reset-captcha"
            class="btn btn-ghost"
            data-confirm={gettext("Go back to the installation's sign-in check?")}
          >
            {gettext("Use the installation's settings")}
          </.button>
        </.form_actions>
      </.form>
    </Layouts.app>
    """
  end

  defp provider_label(p) when is_atom(p), do: provider_label(Atom.to_string(p))
  defp provider_label("pow"), do: gettext("Proof of work (built in)")
  defp provider_label("turnstile"), do: "Cloudflare Turnstile"
  defp provider_label("friendly_captcha"), do: "Friendly Captcha"
  defp provider_label("captcha_eu"), do: "Captcha.eu"
  defp provider_label("none"), do: gettext("None")
  defp provider_label(other), do: other
end
