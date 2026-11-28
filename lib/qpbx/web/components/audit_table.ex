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
    <.live_component
      module={QPBX.Web.PagedTable}
      id={@id}
      rows={@entries}
      search={&search_text(&1, @emails, @tenants)}
      placeholder={gettext("Search by who, what or name")}
      empty={gettext("Nothing recorded yet.")}
    >
      <:col :let={a} label={gettext("When")}>
        <span class="block whitespace-nowrap text-sm font-medium tabular-nums" dir="ltr">
          {local(a.inserted_at, @timezone, "%H:%M:%S")}
        </span>
        <span class="block whitespace-nowrap text-xs text-muted tabular-nums" dir="ltr">
          {local(a.inserted_at, @timezone, "%Y-%m-%d")}
        </span>
      </:col>
      <:col :let={a} :if={@tenants} label={gettext("Tenant")}>
        <span class="text-sm">{tenant(a, @tenants)}</span>
      </:col>
      <:col :let={a} label={gettext("What happened")}>
        <p class="text-sm">
          <span class="font-semibold">{actor(a, @emails)}</span>
          {what(a.action)}
          <span :if={a.target_label && a.target_id != a.actor_id} class="font-medium" dir="auto">
            {a.target_label}
          </span>
        </p>
        <div :if={shown_changes(a.changes) != []} class="mt-1 flex flex-wrap gap-1">
          <.chip :for={{k, v} <- shown_changes(a.changes)} tone={:plain}>
            <span class="opacity-70">{k}:</span> <span dir="ltr">{v}</span>
          </.chip>
        </div>
      </:col>
    </.live_component>
    """
  end

  # A removed tenant's entries keep its name (its id is cleared when the tenant goes).
  defp tenant(%{tenant_id: nil, tenant_label: nil}, _), do: "—"

  defp tenant(%{tenant_id: nil, tenant_label: name}, _),
    do: gettext("%{name} (removed)", name: name)

  defp tenant(a, tenants),
    do: tenants[a.tenant_id] || a.tenant_label || gettext("A removed tenant")

  defp search_text(a, emails, tenants) do
    tenant = if tenants, do: tenant(a, tenants), else: ""
    "#{actor(a, emails)} #{what(a.action)} #{a.target_label} #{tenant}"
  end

  # The changed values worth reading, as short "field: value" pairs (ids left out).
  defp shown_changes(map) when map == %{}, do: []

  defp shown_changes(map) do
    map
    |> Enum.reject(fn {k, v} ->
      is_map(v) or v in [nil, "", []] or String.ends_with?(to_string(k), "_id")
    end)
    |> Enum.take(6)
    |> Enum.map(fn {k, v} -> {String.replace(to_string(k), "_", " "), value(v)} end)
  end

  defp value(true), do: gettext("yes")
  defp value(false), do: gettext("no")
  defp value(v) when is_list(v), do: v |> Enum.map_join(", ", &item/1) |> String.slice(0, 60)
  defp value(v), do: v |> item() |> String.slice(0, 60)

  # A list's items can be maps (a trunk's addresses): their values, side by side.
  defp item(m) when is_map(m), do: m |> Map.values() |> Enum.map_join(" ", &item/1)
  defp item(v) when is_list(v), do: Enum.map_join(v, ", ", &item/1)
  defp item(v), do: to_string(v)

  defp actor(%{actor_type: "system:" <> name}, _), do: gettext("System (%{name})", name: name)

  defp actor(%{actor_type: "api_key"} = a, _),
    do:
      if(a.actor_label,
        do: gettext("API key %{name}", name: a.actor_label),
        else: gettext("API key")
      )

  defp actor(%{actor_id: id, actor_type: "platform_admin"} = a, emails),
    do: emails[id] || a.actor_label || gettext("A removed platform admin")

  defp actor(%{actor_id: id} = a, emails),
    do: emails[id] || a.actor_label || gettext("A removed user")

  defp local(at, tz, format) do
    case DateTime.shift_zone(at, tz) do
      {:ok, l} -> Calendar.strftime(l, format)
      _ -> Calendar.strftime(at, format)
    end
  end

  # What was done, read after who did it ("Dana turned on two-factor authentication").
  defp what("account.setup"), do: gettext("set up their account")
  defp what("account.totp_enable"), do: gettext("turned on two-factor authentication")
  defp what("account.setup_link_issued"), do: gettext("sent a setup link to")
  defp what("account.login_failures_alert"), do: gettext("saw repeated failed logins for")
  defp what("alert_channel.create"), do: gettext("added the alert recipient")
  defp what("alert_channel.update"), do: gettext("changed the alert recipient")
  defp what("alert_channel.delete"), do: gettext("removed the alert recipient")
  defp what("alert_rules.mandatory"), do: gettext("changed the mandatory alert categories")
  defp what("api_key.create"), do: gettext("created the API key")
  defp what("api_key.revoke"), do: gettext("revoked the API key")
  defp what("device.create"), do: gettext("added the device")
  defp what("device.delete"), do: gettext("removed the device")
  defp what("did.create"), do: gettext("added the number")
  defp what("did.update"), do: gettext("changed the number")
  defp what("did.destination"), do: gettext("changed where calls go for")
  defp what("did.delete"), do: gettext("removed the number")
  defp what("edge_ban.lift"), do: gettext("lifted the SIP ban of")

  defp what("edge.office_ip_alert"),
    do: gettext("was warned about failed logins from the office address")

  defp what("edge_settings.update"), do: gettext("changed the SIP protection settings")
  defp what("emergency_route.create"), do: gettext("added the emergency number")
  defp what("emergency_route.delete"), do: gettext("removed the emergency number")
  defp what("extension.create"), do: gettext("created extension")
  defp what("extension.update"), do: gettext("changed extension")
  defp what("extension.delete"), do: gettext("deleted extension")
  defp what("firewall_entry.create"), do: gettext("added the firewall entry")
  defp what("firewall_entry.extend"), do: gettext("extended the firewall entry")
  defp what("firewall_entry.delete"), do: gettext("removed the firewall entry")
  defp what("fraud_block.lift"), do: gettext("lifted the fraud block of")
  defp what("fraud_settings.update"), do: gettext("changed the fraud protection settings")
  defp what("greeting.update"), do: gettext("uploaded a greeting for")
  defp what("greeting.delete"), do: gettext("removed a greeting of")
  defp what("mailbox.update"), do: gettext("changed the voicemail of")
  defp what("mailbox.delete"), do: gettext("removed the voicemail of")
  defp what("notification.resend"), do: gettext("sent a notification again to")
  defp what("number_class.create"), do: gettext("added the destination prefix")
  defp what("number_class.delete"), do: gettext("removed the destination prefix")
  defp what("number_rule.create"), do: gettext("set the number format")
  defp what("number_rule.update"), do: gettext("changed the number format")
  defp what("number_rule.delete"), do: gettext("went back to the default number format")
  defp what("plan.create"), do: gettext("created the plan")
  defp what("plan.update"), do: gettext("changed the plan")
  defp what("platform_admin.create"), do: gettext("added the platform admin")
  defp what("route.create"), do: gettext("created the route")
  defp what("route.update"), do: gettext("changed the route")
  defp what("route.delete"), do: gettext("deleted the route")
  defp what("session.revoke"), do: gettext("signed out a session of")
  defp what("session.revoke_all"), do: gettext("signed out every session of")
  defp what("sip_credential.create"), do: gettext("created the SIP login")
  defp what("sip_credential.reset_password"), do: gettext("made a new SIP password for")
  defp what("sip_credential.delete"), do: gettext("removed the SIP login")
  defp what("tenant.create"), do: gettext("created the tenant")
  defp what("tenant.update"), do: gettext("changed the tenant")
  defp what("trunk.create"), do: gettext("added the trunk")
  defp what("trunk.update"), do: gettext("changed the trunk")
  defp what("trunk.delete"), do: gettext("deleted the trunk")
  defp what("user.create"), do: gettext("added the user")
  defp what("user.role"), do: gettext("changed the role of")
  defp what("user.extension"), do: gettext("linked an extension to")
  defp what("user.delete"), do: gettext("removed the user")
  defp what("voicemail.save"), do: gettext("listened to a voicemail of")
  defp what("voicemail.delete"), do: gettext("deleted a voicemail of")
  defp what("webhook.create"), do: gettext("added the webhook")
  defp what("webhook.update"), do: gettext("changed the webhook")
  defp what("webhook.rotate_secret"), do: gettext("made a new secret for the webhook")
  defp what("webhook.resend"), do: gettext("sent a webhook delivery again to")
  defp what("webhook.delete"), do: gettext("removed the webhook")
  defp what(action), do: action
end
