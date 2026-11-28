defmodule QPBX.Web.Tenant.UsersLive do
  @moduledoc """
  Tenant admin: the company's users. Invite one (a setup link is emailed), link each to their
  own extension (voicemail, calls and forwarding under "My extension"), change roles, remove.
  """
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Core.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Users"), form: to_form(%{"role" => "tenant_user"}, as: :user))
     |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    exts = Core.list_extensions(scope)

    assign(socket,
      users: Core.list_tenant_users(scope),
      ext_options: [{gettext("None"), ""} | Enum.map(exts, &{"#{&1.number} #{&1.name}", &1.id})]
    )
  end

  @impl true
  def handle_event("invite", %{"user" => params}, socket) do
    %{current_scope: scope, current_account: actor} = socket.assigns
    attrs = Map.put(Map.take(params, ~w(name email role extension_id)), "locale", actor.locale)

    case Core.invite_user(scope, attrs, actor) do
      {:ok, user} ->
        {:ok, _} =
          QPBX.Notify.deliver_setup_link(user, QPBX.Web.setup_url(Core.setup_token(user)))

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{email} is invited: a setup link is on its way.", email: user.email)
         )
         |> assign(form: to_form(%{"role" => "tenant_user"}, as: :user))
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs, as: :user, action: :validate))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("That extension is not one of yours."))}
    end
  end

  def handle_event("set_extension", %{"user_id" => id, "extension_id" => ext}, socket),
    do:
      {:noreply,
       result(
         socket,
         Core.set_user_extension(
           socket.assigns.current_scope,
           id,
           ext,
           socket.assigns.current_account
         )
       )}

  def handle_event("set_role", %{"user_id" => id, "role" => role}, socket),
    do:
      {:noreply,
       result(
         socket,
         Core.set_user_role(
           socket.assigns.current_scope,
           id,
           role,
           socket.assigns.current_account
         )
       )}

  def handle_event("setup_link", %{"id" => id}, socket) do
    case Core.user_setup_link(socket.assigns.current_scope, id, socket.assigns.current_account) do
      {:ok, user, token} ->
        QPBX.Web.send_setup_link(user, token)

        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("A setup link was emailed to %{email}.", email: user.email)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("sign_out", %{"id" => id}, socket) do
    case Core.sign_out_user(socket.assigns.current_scope, id, socket.assigns.current_account) do
      {:ok, n} ->
        {:noreply,
         put_flash(socket, :info, gettext("Signed out of %{count} sessions.", count: n))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket),
    do:
      {:noreply,
       result(
         socket,
         Core.delete_user(socket.assigns.current_scope, id, socket.assigns.current_account)
       )}

  defp result(socket, {:ok, _}), do: socket |> put_flash(:info, gettext("Saved.")) |> load()

  defp result(socket, {:error, :last_admin}),
    do:
      socket
      |> put_flash(:error, gettext("The company needs at least one tenant admin."))
      |> load()

  defp result(socket, {:error, :self}),
    do: put_flash(socket, :error, gettext("You cannot remove yourself."))

  defp result(socket, {:error, _}),
    do: socket |> put_flash(:error, gettext("That did not work.")) |> load()

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
        {gettext("Users")}
        <:subtitle>
          {gettext(
            "A user linked to an extension sees its voicemail and calls, and sets its forwarding, under My extension."
          )}
        </:subtitle>
      </.header>

      <.table id="users" rows={@users} row_id={&"user-#{&1.id}"}>
        <:col :let={u} label={gettext("Name")}>{u.name}</:col>
        <:col :let={u} label={gettext("Email")}><span dir="ltr">{u.email}</span></:col>
        <:col :let={u} label={gettext("Role")}>
          <form phx-change="set_role" id={"role-#{u.id}"}>
            <input type="hidden" name="user_id" value={u.id} />
            <select name="role" class="select select-sm">
              {Phoenix.HTML.Form.options_for_select(role_options(), User.role(u))}
            </select>
          </form>
        </:col>
        <:col :let={u} label={gettext("Extension")}>
          <form phx-change="set_extension" id={"ext-#{u.id}"}>
            <input type="hidden" name="user_id" value={u.id} />
            <select name="extension_id" class="select select-sm">
              {Phoenix.HTML.Form.options_for_select(@ext_options, u.extension_id || "")}
            </select>
          </form>
        </:col>
        <:action :let={u}>
          <.link
            phx-click="setup_link"
            phx-value-id={u.id}
            id={"setup-link-#{u.id}"}
            data-confirm={
              gettext(
                "Send %{email} a new setup link? It lets them choose a new password and authenticator.",
                email: u.email
              )
            }
          >
            {gettext("New setup link")}
          </.link>
        </:action>
        <:action :let={u}>
          <.link
            :if={u.id != @current_account.id}
            phx-click="sign_out"
            phx-value-id={u.id}
            id={"sign-out-#{u.id}"}
            data-confirm={gettext("Sign %{email} out everywhere?", email: u.email)}
          >
            {gettext("Sign out everywhere")}
          </.link>
        </:action>
        <:action :let={u}>
          <.link
            :if={u.id != @current_account.id}
            phx-click="delete"
            phx-value-id={u.id}
            id={"delete-user-#{u.id}"}
            data-confirm={gettext("Remove %{email}? They can no longer sign in.", email: u.email)}
          >
            {gettext("Remove")}
          </.link>
        </:action>
      </.table>

      <h2 class="text-lg font-semibold mt-8">{gettext("Invite a user")}</h2>
      <.form for={@form} id="invite-form" phx-submit="invite">
        <div class="grid sm:grid-cols-2 gap-x-4">
          <.input field={@form[:name]} label={gettext("Name")} required />
          <.input field={@form[:email]} type="email" label={gettext("Email")} dir="ltr" required />
          <.input field={@form[:role]} type="select" label={gettext("Role")} options={role_options()} />
          <.input
            field={@form[:extension_id]}
            type="select"
            label={gettext("Extension")}
            options={@ext_options}
          />
        </div>
        <.button variant="primary">{gettext("Invite")}</.button>
      </.form>
    </Layouts.app>
    """
  end

  defp role_options,
    do: [{gettext("Tenant user"), "tenant_user"}, {gettext("Tenant admin"), "tenant_admin"}]
end
