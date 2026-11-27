defmodule QPBX.Web.AuditTable do
  @moduledoc "The audit log as a table: when, who, what, on what, the change."
  use QPBX.Web, :html

  attr :id, :string, required: true
  attr :entries, :list, required: true
  attr :emails, :map, required: true
  attr :timezone, :string, default: "Etc/UTC"

  attr :tenants, :map,
    default: nil,
    doc: "tenant id => name; adds a tenant column (platform view)"

  def audit_table(assigns) do
    ~H"""
    <p :if={@entries == []} id={"#{@id}-empty"}>{gettext("Nothing recorded yet.")}</p>
    <.table :if={@entries != []} id={@id} rows={@entries}>
      <:col :let={a} label={gettext("When")}>
        <span dir="ltr">{local(a.inserted_at, @timezone)}</span>
      </:col>
      <:col :let={a} :if={@tenants} label={gettext("Tenant")}>{@tenants[a.tenant_id] || "—"}</:col>
      <:col :let={a} label={gettext("Who")}><span dir="ltr">{actor(a, @emails)}</span></:col>
      <:col :let={a} label={gettext("Action")}><code>{a.action}</code></:col>
      <:col :let={a} label={gettext("On")}>{a.target_type}</:col>
      <:col :let={a} label={gettext("Change")}>
        <code class="text-xs break-all" dir="ltr">{changes(a.changes)}</code>
      </:col>
    </.table>
    """
  end

  defp actor(%{actor_type: "system:" <> name}, _), do: gettext("System (%{name})", name: name)

  defp actor(%{actor_id: id, actor_type: "platform_admin"}, emails),
    do: emails[id] || gettext("Platform admin")

  defp actor(%{actor_id: id}, emails), do: emails[id] || gettext("Removed account")

  defp changes(map) when map == %{}, do: ""
  defp changes(map), do: map |> Jason.encode!() |> String.slice(0, 200)

  defp local(at, tz) do
    case DateTime.shift_zone(at, tz) do
      {:ok, l} -> Calendar.strftime(l, "%Y-%m-%d %H:%M:%S")
      _ -> Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
    end
  end
end
