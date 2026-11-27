defmodule QPBX.Web.Platform.TenantsLive do
  @moduledoc "Platform admin: list tenants and create a tenant with its first tenant admin."
  use QPBX.Web, :live_view
  alias QPBX.Core

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, tenants: Core.list_tenants(), plans: Core.list_plans(), setup_link: nil)}
  end

  @impl true
  def handle_params(_params, _url, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action)}

  defp apply_action(socket, :index), do: assign(socket, page_title: gettext("Tenants"))

  defp apply_action(socket, :new) do
    assign(socket,
      page_title: gettext("New tenant"),
      form: to_form(%{"locale" => "en", "timezone" => "Asia/Jerusalem"}, as: :tenant)
    )
  end

  @impl true
  def handle_event("save", %{"tenant" => params}, socket) do
    tenant_attrs = Map.take(params, ~w(name slug timezone locale plan_id))

    admin_attrs = %{
      "name" => params["admin_name"],
      "email" => params["admin_email"],
      "locale" => params["locale"]
    }

    case Core.create_tenant_with_admin(tenant_attrs, admin_attrs, socket.assigns.current_account) do
      {:ok, %{tenant: tenant, admin: admin}} ->
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
         |> assign(tenants: Core.list_tenants(), setup_link: %{email: admin.email, url: url})
         |> push_patch(to: ~p"/platform")}

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
    ~H"""
    <Layouts.app flash={@flash} locale={@locale} current_account={@current_account}>
      <.header>
        {gettext("Tenants")}
        <:actions>
          <.button
            :if={@live_action == :index}
            navigate={~p"/platform/tenants/new"}
            variant="primary"
            id="new-tenant"
          >
            {gettext("New tenant")}
          </.button>
        </:actions>
      </.header>

      <div :if={@setup_link} class="alert alert-info flex-col items-start" id="setup-link">
        <p>
          {gettext("Setup link for %{email} (also emailed). It works once and expires in 48 hours:",
            email: @setup_link.email
          )}
        </p>
        <code class="break-all" dir="ltr">{@setup_link.url}</code>
      </div>

      <.form :if={@live_action == :new} for={@form} id="tenant-form" phx-submit="save">
        <p :if={@plans == []} class="alert alert-warning">
          {gettext("Create a plan first.")}
          <.link navigate={~p"/platform/plans"} class="link">{gettext("Plans")}</.link>
        </p>
        <.input field={@form[:name]} label={gettext("Company name")} required />
        <.input field={@form[:slug]} label={gettext("SIP domain name")} dir="ltr" required />
        <p class="text-sm opacity-70 -mt-2 mb-2" dir="ltr">
          &lt;name&gt;.{QPBX.Core.sip_base_domain()}
        </p>
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
          options={[{"English", "en"}, {"العربية", "ar"}]}
        />
        <h3 class="font-semibold mt-4">{gettext("First tenant admin")}</h3>
        <.input field={@form[:admin_name]} label={gettext("Name")} required />
        <.input
          field={@form[:admin_email]}
          type="email"
          label={gettext("Email")}
          dir="ltr"
          required
        />
        <.button variant="primary" phx-disable-with={gettext("Saving...")}>
          {gettext("Create tenant")}
        </.button>
      </.form>

      <.table :if={@live_action == :index} id="tenants" rows={@tenants}>
        <:col :let={t} label={gettext("Name")}>{t.name}</:col>
        <:col :let={t} label={gettext("SIP domain")}><span dir="ltr">{t.sip_domain}</span></:col>
        <:col :let={t} label={gettext("Plan")}>{t.plan.name}</:col>
        <:col :let={t} label={gettext("Language")}>{t.locale}</:col>
      </.table>
    </Layouts.app>
    """
  end
end
