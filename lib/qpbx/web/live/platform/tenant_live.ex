defmodule QPBX.Web.Platform.TenantLive do
  @moduledoc """
  Platform admin: one tenant. Its name, plan, time zone and language; limit overrides (empty:
  the plan's value); its users, with a new setup link or sign out everywhere for each; another
  tenant admin.
  """
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Core.{Plan, User}
  alias QPBX.Web.PlanFields
  alias QPBX.Web.Platform.PlansLive

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        {:ok,
         socket
         |> assign(
           plans: Core.list_plans(),
           setup_link: nil,
           admin_form: to_form(%{}, as: :admin)
         )
         |> load(Core.get_tenant!(id))}

      :error ->
        {:ok, push_navigate(socket, to: ~p"/platform/tenants")}
    end
  end

  defp load(socket, tenant) do
    assign(socket,
      page_title: tenant.name,
      tenant: tenant,
      form: tenant_form(Core.change_tenant(tenant)),
      users: Core.list_users(%Core.Scope{kind: :platform}, tenant)
    )
  end

  # Overrides show as one field per limit (override_<limit>); empty means "the plan's".
  defp tenant_form(cs) do
    overrides = Ecto.Changeset.get_field(cs, :limit_overrides) || %{}
    form = to_form(cs, as: :tenant)

    extra =
      for l <- Plan.limits(),
          into: %{},
          do: {"override_#{l}", to_string(overrides[to_string(l)] || "")}

    Map.update!(form, :params, &Map.merge(extra, &1))
  end

  @impl true
  def handle_event("save", %{"tenant" => params}, socket) do
    overrides =
      for l <- Plan.limits(), v = params["override_#{l}"], v not in [nil, ""], into: %{} do
        case Integer.parse(v) do
          {n, ""} -> {to_string(l), n}
          _ -> {to_string(l), v}
        end
      end

    attrs =
      params
      |> Map.take(~w(name plan_id timezone locale))
      |> Map.put("limit_overrides", overrides)
      |> Map.put(
        "usage_thresholds",
        PlansLive.parse_percents(params["usage_thresholds"])
      )

    case Core.update_tenant(socket.assigns.tenant, attrs, socket.assigns.current_account) do
      {:ok, tenant} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Saved.")) |> load(Core.get_tenant!(tenant.id))}

      {:error, cs} ->
        {:noreply, assign(socket, form: tenant_form(Map.put(cs, :action, :validate)))}
    end
  end

  def handle_event("add_admin", %{"admin" => params}, socket) do
    %{tenant: tenant, current_account: actor} = socket.assigns
    attrs = params |> Map.take(~w(name email)) |> Map.put("locale", tenant.locale)

    case Core.create_user(tenant, attrs, "tenant_admin", actor) do
      {:ok, user} ->
        {:noreply,
         socket
         |> link_sent(user, actor)
         |> assign(admin_form: to_form(%{}, as: :admin))
         |> load(tenant)}

      {:error, cs} ->
        {:noreply, assign(socket, admin_form: to_form(cs, as: :admin, action: :validate))}
    end
  end

  def handle_event("setup_link", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.users, &(&1.id == id)) do
      nil -> {:noreply, socket}
      user -> {:noreply, link_sent(socket, user, socket.assigns.current_account)}
    end
  end

  def handle_event("sign_out", %{"id" => id}, socket) do
    with %User{} = user <- Enum.find(socket.assigns.users, &(&1.id == id)),
         {:ok, n} <- Core.revoke_sessions(user, socket.assigns.current_account) do
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
      <header class="flex flex-wrap items-center justify-between gap-3 pb-2">
        <div class="flex items-center gap-3 min-w-0">
          <.avatar name={@tenant.name} size={:lg} />
          <div class="min-w-0">
            <h1 class="text-2xl font-semibold leading-tight tracking-tight truncate">
              {@tenant.name}
            </h1>
            <p class="mt-1 flex flex-wrap items-center gap-x-2 text-sm text-muted">
              <span dir="ltr">{@tenant.sip_domain}</span>
              <span aria-hidden="true">·</span>
              <span>{@tenant.plan && @tenant.plan.name}</span>
              <span aria-hidden="true">·</span>
              <span>{ngettext("1 user", "%{count} users", length(@users))}</span>
            </p>
          </div>
        </div>
        <.link navigate={~p"/platform/tenants"} class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="size-4 rtl:rotate-180" /> {gettext("All tenants")}
        </.link>
      </header>

      <.setup_link link={@setup_link} />

      <.form for={@form} id="tenant-form" phx-submit="save">
        <div class="divide-y divide-base-300">
          <.section title={gettext("Details")} icon="hero-building-office-2">
            <div class="grid sm:grid-cols-2 gap-x-4">
              <.input field={@form[:name]} label={gettext("Company name")} required />
              <.input
                field={@form[:plan_id]}
                type="select"
                label={gettext("Plan")}
                options={Enum.map(@plans, &{&1.name, &1.id})}
              />
              <.input field={@form[:timezone]} label={gettext("Time zone")} dir="ltr" />
              <.input
                field={@form[:locale]}
                type="select"
                label={gettext("Language")}
                options={Enum.map(Application.fetch_env!(:qpbx, :locales), &{&1.name, &1.code})}
              />
            </div>
          </.section>

          <.section
            title={gettext("Usage alerts")}
            icon="hero-bell-alert"
            hint={gettext("Percentages of the monthly outbound minutes. Empty: the plan's.")}
          >
            <div class="max-w-md">
              <.input
                name="tenant[usage_thresholds]"
                id="tenant_usage_thresholds"
                value={
                  PlansLive.percents_text(Ecto.Changeset.get_field(@form.source, :usage_thresholds))
                }
                label={gettext("Usage alerts at (%); empty: the plan's")}
                placeholder={PlansLive.percents_text(@tenant.plan && @tenant.plan.usage_thresholds)}
                dir="ltr"
                errors={Enum.map(@form[:usage_thresholds].errors, &translate_error/1)}
              />
            </div>
          </.section>

          <p
            :for={{_k, msg} <- Keyword.take(@form.errors, [:limit_overrides])}
            class="text-error text-sm pt-5"
          >
            {translate_error(msg)}
          </p>
          <PlanFields.limits
            hint={
              gettext(
                "Leave a field empty to use the plan's value (shown as the hint). 0 means none allowed."
              )
            }
            input={
              fn l ->
                %{
                  name: "tenant[override_#{l}]",
                  id: "override_#{l}",
                  value: @form.params["override_#{l}"],
                  placeholder: plan_value(@tenant.plan, l)
                }
              end
            }
          />
        </div>
        <.form_actions>
          <.button variant="primary">{gettext("Save")}</.button>
        </.form_actions>
      </.form>

      <h2>{gettext("Users")}</h2>
      <.table id="tenant-users" rows={@users} row_id={&"user-#{&1.id}"}>
        <:col :let={u} label={gettext("Name")}>
          <span class="font-medium">{u.name}</span>
          <span class="block text-xs text-muted" dir="ltr">{u.email}</span>
        </:col>
        <:col :let={u} label={gettext("Role")}>
          <.chip tone={if User.role(u) == "tenant_admin", do: :brand, else: :plain}>
            {role_label(User.role(u))}
          </.chip>
        </:col>
        <:action :let={u}>
          <.link
            phx-click="setup_link"
            phx-value-id={u.id}
            id={"setup-link-#{u.id}"}
            class="btn btn-ghost btn-xs"
            data-confirm={
              gettext(
                "Send %{email} a new setup link? It lets them choose a new password and authenticator.",
                email: u.email
              )
            }
          >
            <.icon name="hero-envelope" class="size-4" /> {gettext("New setup link")}
          </.link>
        </:action>
        <:action :let={u}>
          <.link
            phx-click="sign_out"
            phx-value-id={u.id}
            id={"sign-out-#{u.id}"}
            class="btn btn-ghost btn-xs text-error"
            data-confirm={gettext("Sign %{email} out everywhere?", email: u.email)}
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4 rtl:rotate-180" />
            {gettext("Sign out everywhere")}
          </.link>
        </:action>
      </.table>

      <.form for={@admin_form} id="tenant-admin-form" phx-submit="add_admin">
        <.section
          title={gettext("Add a tenant admin")}
          icon="hero-user-plus"
          hint={gettext("They get an email with a link to choose a password and set up 2FA.")}
        >
          <div class="grid sm:grid-cols-[1fr_1fr_auto] gap-x-4 items-end">
            <.input field={@admin_form[:name]} label={gettext("Name")} required />
            <.input
              field={@admin_form[:email]}
              type="email"
              label={gettext("Email")}
              dir="ltr"
              required
            />
            <.button variant="primary" class="mb-2">{gettext("Add")}</.button>
          </div>
        </.section>
      </.form>
    </Layouts.app>
    """
  end

  defp plan_value(nil, _), do: gettext("Unlimited")
  defp plan_value(plan, l), do: to_string(Map.get(plan, l) || gettext("Unlimited"))

  defp role_label("tenant_admin"), do: gettext("Tenant admin")
  defp role_label(_), do: gettext("Tenant user")
end
