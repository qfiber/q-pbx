defmodule QPBX.Web.Platform.AdminsLive do
  @moduledoc """
  Platform admin: the platform admins. Add one (a setup link is emailed and shown once), send
  a new setup link (a lost password or authenticator), sign someone out everywhere.
  """
  use QPBX.Web, :live_view
  alias QPBX.Core

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Platform admins"),
       admins: Core.list_platform_admins(),
       form: to_form(Core.change_platform_admin(), as: :admin),
       setup_link: nil
     )}
  end

  @impl true
  def handle_event("add", %{"admin" => params}, socket) do
    actor = socket.assigns.current_account

    case Core.create_platform_admin(Map.take(params, ~w(name email)), actor) do
      {:ok, admin} ->
        {:noreply,
         socket
         |> link_sent(admin, actor)
         |> assign(
           admins: Core.list_platform_admins(),
           form: to_form(Core.change_platform_admin(), as: :admin)
         )}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(cs, as: :admin, action: :validate))}
    end
  end

  def handle_event("setup_link", %{"id" => id}, socket) do
    case Core.get_platform_admin(id) do
      nil -> {:noreply, socket}
      admin -> {:noreply, link_sent(socket, admin, socket.assigns.current_account)}
    end
  end

  def handle_event("sign_out", %{"id" => id}, socket) do
    with %{} = admin <- Core.get_platform_admin(id),
         {:ok, n} <- Core.revoke_sessions(admin, socket.assigns.current_account) do
      {:noreply, put_flash(socket, :info, gettext("Signed out of %{count} sessions.", count: n))}
    else
      _ -> {:noreply, socket}
    end
  end

  defp link_sent(socket, account, actor) do
    {:ok, token} = Core.issue_setup_link(account, actor)
    url = QPBX.Web.send_setup_link(account, token)

    socket
    |> put_flash(:info, gettext("A setup link was emailed to %{email}.", email: account.email))
    |> assign(setup_link: %{email: account.email, url: url})
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
        {gettext("Platform admins")}
        <:subtitle>
          {gettext(
            "They manage every tenant, carrier and setting. Two-factor authentication is required for them."
          )}
        </:subtitle>
      </.header>

      <.setup_link link={@setup_link} />

      <.live_component
        module={PagedTable}
        id="admins"
        rows={@admins}
        row_id={&"admin-#{&1.id}"}
        search={&"#{&1.name} #{&1.email}"}
        placeholder={gettext("Search by name or email")}
      >
        <:col :let={a} label={gettext("Name")}>
          <div class="flex items-center gap-3">
            <.avatar name={a.name} size={:sm} />
            <div>
              <span class="font-medium">{a.name}</span>
              <span class="block text-xs text-muted" dir="ltr">{a.email}</span>
            </div>
          </div>
        </:col>
        <:col :let={a} label={gettext("Two-factor")}>
          <.chip :if={Core.totp_enabled?(a)} tone={:ok}>{gettext("On")}</.chip>
          <.chip :if={!Core.totp_enabled?(a)} tone={:warm}>{gettext("Not set up yet")}</.chip>
        </:col>
        <:action :let={a}>
          <.link
            phx-click="setup_link"
            phx-value-id={a.id}
            id={"setup-link-#{a.id}"}
            class="btn btn-ghost btn-xs"
            data-confirm={
              gettext(
                "Send %{email} a new setup link? It lets them choose a new password and authenticator.",
                email: a.email
              )
            }
          >
            <.icon name="hero-envelope" class="size-4" /> {gettext("New setup link")}
          </.link>
        </:action>
        <:action :let={a}>
          <.link
            phx-click="sign_out"
            phx-value-id={a.id}
            id={"sign-out-#{a.id}"}
            class="btn btn-ghost btn-xs text-error"
            data-confirm={gettext("Sign %{email} out everywhere?", email: a.email)}
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4 rtl:rotate-180" />
            {gettext("Sign out everywhere")}
          </.link>
        </:action>
      </.live_component>

      <.form for={@form} id="admin-form" phx-submit="add">
        <.section
          title={gettext("Add a platform admin")}
          icon="hero-user-plus"
          hint={gettext("They get an email with a link to choose a password and set up 2FA.")}
        >
          <div class="grid sm:grid-cols-[1fr_1fr_auto] gap-x-4 items-end">
            <.input field={@form[:name]} label={gettext("Name")} required />
            <.input field={@form[:email]} type="email" label={gettext("Email")} dir="ltr" required />
            <.button variant="primary" class="mb-2">{gettext("Add")}</.button>
          </div>
        </.section>
      </.form>
    </Layouts.app>
    """
  end
end
