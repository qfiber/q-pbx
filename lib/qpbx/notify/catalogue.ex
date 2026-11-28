defmodule QPBX.Notify.Catalogue do
  @moduledoc """
  The alert catalogue: each kind's category, severity and default audience (spec,
  "Notifications and alerts"). Audiences: `:platform_admins`, `:tenant_admins` (of the alert's
  tenant), `:user` (the alert's user). A platform alert (no tenant) never goes to tenant
  admins. Sources raise alerts by kind (3-9); `test` is the test notification.
  """
  @categories ~w(security health usage operations personal)
  @severities ~w(info warning critical)

  @kinds %{
    "test" => {nil, "info", [:platform_admins, :tenant_admins]},
    "sip_attack" => {"security", "critical", [:platform_admins, :tenant_admins]},
    "brute_force" => {"security", "warning", [:tenant_admins, :platform_admins]},
    "unusual_activity" => {"security", "critical", [:tenant_admins, :platform_admins]},
    "fraud_block" => {"security", "critical", [:tenant_admins]},
    "login_new_ip" => {"security", "warning", [:user]},
    "service_down" => {"health", "critical", [:platform_admins]},
    "failover" => {"health", "critical", [:platform_admins]},
    "trunk_down" => {"health", "critical", [:platform_admins, :tenant_admins]},
    "call_quality" => {"health", "warning", [:platform_admins]},
    "disk" => {"health", "warning", [:platform_admins]},
    "backup_failed" => {"health", "warning", [:platform_admins]},
    "certificate_expiring" => {"health", "warning", [:platform_admins]},
    "usage_threshold" => {"usage", "info", [:tenant_admins]},
    "limit_reached" => {"usage", "critical", [:tenant_admins]},
    "usage_summary" => {"usage", "info", [:tenant_admins]},
    "device_offline" => {"operations", "warning", [:tenant_admins]},
    "webhook_dead" => {"operations", "warning", [:tenant_admins]},
    "missed_call" => {"personal", "info", [:user]},
    "voicemail" => {"personal", "info", [:user]}
  }

  def categories, do: @categories
  def severities, do: @severities
  def kinds, do: Map.keys(@kinds)

  @doc "`{category, severity, audience}` of a kind (`test`: the category is chosen when sent)."
  def kind(kind), do: Map.fetch!(@kinds, kind)

  @doc """
  A person's channels when they chose none: the portal and email. A person's email carries
  warning and critical alerts only (info stays in the portal); shared recipients choose their
  own minimum severity.
  """
  def default_channels, do: ~w(portal email)

  @doc "True when a person's email channel carries alerts of this severity."
  def person_email?(severity), do: severity in ~w(critical warning)

  @doc "True when `severity` is at least `min`."
  def at_least?(severity, min), do: rank(severity) >= rank(min)

  defp rank("critical"), do: 2
  defp rank("warning"), do: 1
  defp rank(_), do: 0
end
