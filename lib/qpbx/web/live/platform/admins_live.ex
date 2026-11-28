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

      <div :if={@setup_link} class="alert alert-info flex-col items-start" id="setup-link">
        <p>
          {gettext("Setup link for %{email} (also emailed). It works once and expires in 48 hours:",
            email: @setup_link.email
          )}
        </p>
        <code class="break-all" dir="ltr">{@setup_link.url}</code>
      </div>

      <.table id="admins" rows={@admins} row_id={&"admin-#{&1.id}"}>
        <:col :let={a} label={gettext("Name")}>{a.name}</:col>
        <:col :let={a} label={gettext("Email")}><span dir="ltr">{a.email}</span></:col>
        <:col :let={a} label={gettext("Two-factor")}>
          {if Core.totp_enabled?(a), do: gettext("On"), else: gettext("Not set up yet")}
        </:col>
        <:action :let={a}>
          <.link
            phx-click="setup_link"
            phx-value-id={a.id}
            id={"setup-link-#{a.id}"}
            data-confirm={
              gettext(
                "Send %{email} a new setup link? It lets them choose a new password and authenticator.",
                email: a.email
              )
            }
          >
            {gettext("New setup link")}
          </.link>
        </:action>
        <:action :let={a}>
          <.link
            phx-click="sign_out"
            phx-value-id={a.id}
            id={"sign-out-#{a.id}"}
            data-confirm={gettext("Sign %{email} out everywhere?", email: a.email)}
          >
            {gettext("Sign out everywhere")}
          </.link>
        </:action>
      </.table>

      <h2 class="text-lg font-semibold mt-8">{gettext("Add a platform admin")}</h2>
      <.form for={@form} id="admin-form" phx-submit="add">
        <div class="grid sm:grid-cols-2 gap-x-4">
          <.input field={@form[:name]} label={gettext("Name")} required />
          <.input field={@form[:email]} type="email" label={gettext("Email")} dir="ltr" required />
        </div>
        <.button variant="primary">{gettext("Add")}</.button>
      </.form>
    </Layouts.app>
    """
  end
end
