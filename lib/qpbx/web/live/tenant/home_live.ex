defmodule QPBX.Web.Tenant.HomeLive do
  @moduledoc "Tenant portal landing page (phase 1 shell)."
  use QPBX.Web, :live_view
  alias QPBX.Core

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: gettext("Home"))}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale} current_account={@current_account}>
      <.header>
        {@current_account.tenant.name}
        <:subtitle><span dir="ltr">{@current_account.tenant.sip_domain}</span></:subtitle>
      </.header>
      <ul class="list-disc ps-6" id="account-summary">
        <li>{gettext("Signed in as %{name}", name: @current_account.name)}</li>
        <li>{role_label(QPBX.Core.User.role(@current_account))}</li>
        <li :if={Core.totp_enabled?(@current_account)}>
          {gettext("Two-factor authentication is on.")}
        </li>
        <li :if={!Core.totp_enabled?(@current_account)}>
          {gettext("Two-factor authentication is off.")}
        </li>
      </ul>
    </Layouts.app>
    """
  end

  defp role_label("tenant_admin"), do: gettext("Tenant admin")
  defp role_label("tenant_user"), do: gettext("Tenant user")
end
