defmodule QPBX.Web.Platform.AuditLive do
  @moduledoc "Platform admin: the audit log of every tenant and the platform (latest 300), by tenant."
  use QPBX.Web, :live_view
  import QPBX.Web.AuditTable
  alias QPBX.Core

  @impl true
  def mount(_params, _session, socket) do
    tenants = Core.list_tenants()

    {:ok,
     assign(socket,
       page_title: gettext("Audit log"),
       tenants: Map.new(tenants, &{&1.id, &1.name}),
       tenant_options: [{gettext("All"), ""} | Enum.map(tenants, &{&1.name, &1.id})]
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    opts =
      [limit: 300] ++
        if params["tenant"] in [nil, ""], do: [], else: [tenant_id: params["tenant"]]

    entries = Core.list_audit_logs(opts)

    {:noreply,
     assign(socket,
       entries: entries,
       emails: Core.account_emails(Enum.map(entries, & &1.actor_id)),
       filter: to_form(%{"tenant" => params["tenant"] || ""}, as: :f)
     )}
  rescue
    Ecto.Query.CastError -> {:noreply, push_patch(socket, to: ~p"/platform/audit")}
  end

  @impl true
  def handle_event("filter", %{"f" => %{"tenant" => t}}, socket),
    do:
      {:noreply,
       push_patch(socket, to: ~p"/platform/audit?#{if t == "", do: %{}, else: %{tenant: t}}")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      locale={@locale}
      current_account={@current_account}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("Audit log")}
        <:subtitle>
          {gettext("Every change made by people and by the system, newest first. Times in UTC.")}
        </:subtitle>
      </.header>
      <.form for={@filter} id="audit-filter" phx-change="filter">
        <.input
          field={@filter[:tenant]}
          type="select"
          label={gettext("Tenant")}
          options={@tenant_options}
        />
      </.form>
      <.audit_table id="audit" entries={@entries} emails={@emails} tenants={@tenants} />
    </Layouts.app>
    """
  end
end
