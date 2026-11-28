defmodule QPBX.Web.Tenant.AuditLive do
  @moduledoc "Tenant admin: the company's own audit log (latest 200)."
  use QPBX.Web, :live_view
  import QPBX.Web.AuditTable
  alias QPBX.Core

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    entries = Core.list_my_audit_logs(scope)

    {:ok,
     assign(socket,
       page_title: gettext("Audit log"),
       entries: entries,
       # Only the company's own users are named; platform admins show as such.
       emails: Core.account_emails(Enum.map(entries, & &1.actor_id), scope.tenant_id)
     )}
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
        {gettext("Audit log")}
        <:subtitle>{gettext("Every change to your company's settings, newest first.")}</:subtitle>
      </.header>
      <.audit_table
        id="audit"
        entries={@entries}
        emails={@emails}
        timezone={@current_account.tenant.timezone}
      />
    </Layouts.app>
    """
  end
end
