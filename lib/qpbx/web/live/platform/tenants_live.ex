defmodule QPBX.Web.Platform.TenantsLive do
  @moduledoc "Platform admin: list tenants and create a tenant with its first tenant admin."
  use QPBX.Web, :live_view
  alias QPBX.Core
  alias QPBX.Web.{Pager, PlanFields}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       tenants: Core.list_tenants(),
       plans: Core.list_plans(),
       setup_link: nil,
       query: ""
     )}
  end

  @impl true
  def handle_params(params, _url, socket),
    do:
      {:noreply,
       socket |> assign(page: params["page"]) |> apply_action(socket.assigns.live_action)}

  defp apply_action(socket, :index), do: assign(socket, page_title: gettext("Tenants"))

  defp apply_action(socket, :new) do
    assign(socket,
      page_title: gettext("New tenant"),
      form: to_form(%{"locale" => "en", "timezone" => "Asia/Jerusalem"}, as: :tenant)
    )
  end

  @impl true
  def handle_event("filter", %{"q" => q}, socket),
    do: {:noreply, assign(socket, query: q, page: 1)}

  def handle_event("save", %{"tenant" => params}, socket) do
    tenant_attrs = Map.take(params, ~w(name slug timezone locale plan_id))

    admin_attrs = %{
      "name" => params["admin_name"],
      "email" => params["admin_email"],
      "locale" => params["locale"]
    }

    case Core.create_tenant_with_admin(tenant_attrs, admin_attrs, socket.assigns.current_account) do
      {:ok, %{tenant: tenant, admin: admin}} ->
        tenants = Core.list_tenants()
        url = QPBX.Web.setup_url(Core.setup_token(admin))
        {:ok, _job} = QPBX.Notify.deliver_setup_link(admin, url)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Tenant %{name} created. A setup link was emailed to %{email}.",
             name: tenant.name,
             email: admin.email
           )
         )
         |> assign(tenants: tenants, setup_link: %{email: admin.email, url: url}, query: "")
         |> push_patch(to: ~p"/platform/tenants?page=#{Pager.page_of(tenants, tenant.id)}")}

      {:error, step, cs} ->
        errors = Enum.map(cs.errors, fn {field, error} -> {error_key(step, field), error} end)

        {:noreply,
         assign(socket, form: to_form(params, as: :tenant, errors: errors, action: :validate))}
    end
  end

  # The form mixes tenant and admin fields; admin ones carry an admin_ prefix.
  defp error_key(:tenant, field), do: field
  defp error_key(:admin, :email), do: :admin_email
  defp error_key(:admin, :name), do: :admin_name
  defp error_key(:admin, field), do: field

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :paged,
        Pager.paginate(matching(assigns.tenants, assigns.query), assigns.page)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      locale={@locale}
      current_account={@current_account}
      unread={assigns[:unread]}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {if @live_action == :new, do: gettext("New tenant"), else: gettext("Tenants")}
        <:subtitle>
          {if @live_action == :new,
            do: gettext("A company on this platform, with its own SIP domain, plan and admin."),
            else: ngettext("1 tenant", "%{count} tenants", length(@tenants))}
        </:subtitle>
        <:actions>
          <.button
            :if={@live_action == :index}
            navigate={~p"/platform/tenants/new"}
            variant="primary"
            id="new-tenant"
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("New tenant")}
          </.button>
          <.link
            :if={@live_action == :new}
            navigate={~p"/platform/tenants"}
            class="btn btn-ghost btn-sm"
          >
            {gettext("All tenants")}
          </.link>
        </:actions>
      </.header>

      <.setup_link_notice link={@setup_link} />

      <.form :if={@live_action == :new} for={@form} id="tenant-form" phx-submit="save">
        <p :if={@plans == []} class="alert alert-warning mb-4">
          {gettext("Create a plan first.")}
          <.link navigate={~p"/platform/plans"} class="link">{gettext("Plans")}</.link>
        </p>
        <div class="divide-y divide-base-300">
          <PlanFields.section title={gettext("Company")} icon="hero-building-office-2">
            <div class="grid sm:grid-cols-2 gap-x-4">
              <.input field={@form[:name]} label={gettext("Company name")} required />
              <div>
                <.input field={@form[:slug]} label={gettext("SIP domain name")} dir="ltr" required />
                <p class="text-xs text-muted -mt-1 mb-2" dir="ltr">
                  &lt;name&gt;.{QPBX.Core.sip_base_domain()}
                </p>
              </div>
              <.input
                field={@form[:plan_id]}
                type="select"
                label={gettext("Plan")}
                options={Enum.map(@plans, &{&1.name, &1.id})}
                required
              />
              <.input field={@form[:timezone]} label={gettext("Time zone")} dir="ltr" required />
              <.input
                field={@form[:locale]}
                type="select"
                label={gettext("Language")}
                options={QPBX.Web.Locale.options()}
              />
            </div>
          </PlanFields.section>
          <PlanFields.section
            title={gettext("First tenant admin")}
            icon="hero-user-plus"
            hint={gettext("They get an email with a link to choose a password and set up 2FA.")}
          >
            <div class="grid sm:grid-cols-2 gap-x-4">
              <.input field={@form[:admin_name]} label={gettext("Name")} required />
              <.input
                field={@form[:admin_email]}
                type="email"
                label={gettext("Email")}
                dir="ltr"
                required
              />
            </div>
          </PlanFields.section>
        </div>
        <div class="pt-5 mt-2 border-t border-base-300">
          <.button variant="primary" phx-disable-with={gettext("Saving...")}>
            {gettext("Create tenant")}
          </.button>
        </div>
      </.form>

      <div :if={@live_action == :index} class="space-y-4">
        <form phx-change="filter" phx-submit="filter" id="tenant-search" class="max-w-sm">
          <label class="input w-full">
            <.icon name="hero-magnifying-glass" class="size-4 text-muted" />
            <input
              type="search"
              name="q"
              value={@query}
              placeholder={gettext("Search by name or domain")}
              phx-debounce="200"
              autocomplete="off"
            />
          </label>
        </form>
        <.table
          id="tenants"
          rows={@paged.items}
          row_click={&JS.navigate(~p"/platform/tenants/#{&1.id}")}
        >
          <:col :let={t} label={gettext("Tenant")}>
            <div class="flex items-center gap-3">
              <div class="size-9 shrink-0 rounded-[8px] bg-brand-pale text-primary grid place-items-center font-semibold">
                {t.name |> String.first() |> String.upcase()}
              </div>
              <div class="min-w-0">
                <.link
                  navigate={~p"/platform/tenants/#{t.id}"}
                  class="font-semibold hover:underline"
                  id={"tenant-#{t.id}"}
                >
                  {t.name}
                </.link>
                <span class="block text-xs text-muted truncate" dir="ltr">{t.sip_domain}</span>
              </div>
            </div>
          </:col>
          <:col :let={t} label={gettext("Plan")}>
            <span class="rounded-[6px] bg-accent-pale text-secondary px-2 py-0.5 text-xs font-medium">
              {t.plan.name}
            </span>
          </:col>
          <:col :let={t} label={gettext("Language")}>{QPBX.Web.Locale.name(t.locale)}</:col>
          <:col :let={t} label={gettext("Since")}>
            <span class="text-muted">{Calendar.strftime(t.inserted_at, "%Y-%m-%d")}</span>
          </:col>
        </.table>
        <Pager.pager id="tenants-pages" page={@paged} to={&~p"/platform/tenants?page=#{&1}"} />
        <p :if={@paged.total == 0 and @query != ""} class="text-sm text-muted">
          {gettext("No tenant matches \"%{q}\".", q: @query)}
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp matching(tenants, ""), do: tenants

  defp matching(tenants, q) do
    q = String.downcase(String.trim(q))

    Enum.filter(tenants, fn t ->
      String.contains?(String.downcase(t.name), q) or String.contains?(t.sip_domain, q)
    end)
  end

  attr :link, :map, default: nil

  @doc false
  def setup_link_notice(assigns) do
    ~H"""
    <div
      :if={@link}
      class="rounded-[12px] border border-secondary/30 bg-accent-pale p-4 space-y-2"
      id="setup-link"
    >
      <p class="flex items-center gap-2 text-sm font-medium">
        <.icon name="hero-envelope" class="size-5 text-secondary" />
        {gettext("Setup link for %{email} (also emailed). It works once and expires in 48 hours:",
          email: @link.email
        )}
      </p>
      <code
        class="block break-all rounded-[8px] bg-base-100 border border-hairline p-2 text-xs"
        dir="ltr"
      >
        {@link.url}
      </code>
    </div>
    """
  end
end
