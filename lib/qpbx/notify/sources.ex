defmodule QPBX.Notify.Sources do
  @moduledoc """
  Where alerts come from: bus events become alerts (`actions/1`, pure: each event to
  `{:raise, attrs}` and `{:resolve, tenant_id, key}`), run by this process.

  - Security: Kamailio bans (`EdgeBanned`: failed SIP logins against a tenant's domain are that
    tenant's brute force; floods, scanners and rate bans are platform SIP attacks), office IPs
    that would have been banned (`EdgeAlert`), fraud rules (`FraudAlert`: blocked or not),
    portal logins (`LoginAlert`: a new address, a failed 2FA code, failures on an account, a
    blocked address).
  - Health: health checks (`HealthChanged`: FreeSWITCH, Kamailio, PostgreSQL down; disk,
    certificate, backups, the job backlog), trunks (`TrunkStatusChanged`), crash loops (3
    crashes of one kind of process within 5 minutes, from `QPBX.Notify.CrashWatch`).
  - Usage: thresholds (`UsageThresholdReached`), limits reached (`LimitReached`), the monthly
    summary (`UsageSummary`).
  - Operations: a phone unregistered for longer than `offline_minutes` (15 by default; config
    `:qpbx, QPBX.Notify`), a webhook given up (`WebhookDeadLettered`).
  - Personal: missed calls and voicemail, to the user of the extension.

  Recovery resolves: a component back to ok, a trunk back up, a phone registered again.
  """
  use GenServer
  require Logger
  alias QPBX.Core
  alias QPBX.Events

  alias QPBX.Events.{
    CallEvent,
    EdgeAlert,
    EdgeBanned,
    ExtensionRegistration,
    FraudAlert,
    HealthChanged,
    LimitReached,
    LoginAlert
  }

  alias QPBX.Events.{
    TrunkStatusChanged,
    UsageSummary,
    UsageThresholdReached,
    VoicemailReceived,
    WebhookDeadLettered
  }

  alias QPBX.Notify.Alerts

  @sources [
    EdgeBanned,
    EdgeAlert,
    FraudAlert,
    LoginAlert,
    HealthChanged,
    TrunkStatusChanged,
    UsageThresholdReached,
    UsageSummary,
    LimitReached,
    WebhookDeadLettered,
    CallEvent,
    VoicemailReceived,
    ExtensionRegistration
  ]
  @crash_window 5 * 60
  @crash_count 3

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # From QPBX.Notify.CrashWatch (the logger handler): a process of this kind crashed.
  def crashed(kind),
    do: GenServer.cast(__MODULE__, {:crashed, kind, System.monotonic_time(:second)})

  @impl true
  def init(_) do
    for s <- @sources, do: Events.subscribe(s)
    QPBX.Notify.CrashWatch.install()
    {:ok, %{offline: %{}, crashes: %{}}}
  end

  @impl true
  def handle_info({:event, %ExtensionRegistration{} = e}, s), do: {:noreply, registration(e, s)}

  def handle_info({:event, event}, s) do
    run(actions(event))
    {:noreply, s}
  end

  def handle_info({:offline, key, attrs}, s) do
    if Map.has_key?(s.offline, key), do: run([{:raise, attrs}])
    {:noreply, %{s | offline: Map.delete(s.offline, key)}}
  end

  @impl true
  def handle_cast({:crashed, kind, at}, s) do
    times = Enum.filter([at | s.crashes[kind] || []], &(at - &1 < @crash_window))

    if length(times) >= @crash_count do
      run([
        {:raise,
         %{
           kind: "crash_loop",
           key: "crash:#{kind}",
           title: "Crash loop: #{kind}",
           message: "#{kind} crashed #{length(times)} times within 5 minutes.",
           data: %{process: kind}
         }}
      ])
    end

    {:noreply, %{s | crashes: Map.put(s.crashes, kind, times)}}
  end

  # An unregistered phone: an alert if it stays away; registered again: cancelled or resolved.
  defp registration(%ExtensionRegistration{type: "unregistered"} = e, s) do
    key = "offline:#{e.device}"

    attrs = %{
      kind: "device_offline",
      key: key,
      tenant_id: e.tenant_id,
      title: "Phone offline: #{e.device}",
      message:
        "Device #{e.device} of extension #{e.extension} has been unregistered for more than #{offline_minutes()} minutes (#{e.reason}).",
      data: %{device: e.device, extension_id: e.extension_id}
    }

    # offline_ms: tests only.
    ms = Application.get_env(:qpbx, QPBX.Notify, [])[:offline_ms] || offline_minutes() * 60_000
    ref = Process.send_after(self(), {:offline, {e.tenant_id, key}, attrs}, ms)

    %{s | offline: Map.put(s.offline, {e.tenant_id, key}, ref)}
  end

  defp registration(%ExtensionRegistration{type: "registered"} = e, s) do
    key = {e.tenant_id, "offline:#{e.device}"}
    if ref = s.offline[key], do: Process.cancel_timer(ref)
    run([{:resolve, e.tenant_id, "offline:#{e.device}"}])
    %{s | offline: Map.delete(s.offline, key)}
  end

  defp offline_minutes, do: Application.get_env(:qpbx, QPBX.Notify, [])[:offline_minutes] || 15

  defp run(actions) do
    for a <- actions do
      case a do
        {:raise, attrs} -> {:ok, _} = Alerts.raise(attrs)
        {:resolve, tid, key} -> :ok = Alerts.resolve_key(tid, key)
      end
    end

    :ok
  rescue
    e -> Logger.error("alerts: an alert source failed: #{Exception.message(e)}")
  end

  @doc "The alerts an event calls for."
  def actions(%EdgeBanned{reason: "auth failures", domain: domain} = e) when is_binary(domain) do
    where = if e.port, do: "#{e.ip}:#{e.port}", else: e.ip

    [
      {:raise,
       %{
         kind: "brute_force",
         key: "sip_auth:#{e.ip}",
         tenant_id: Core.tenant_id_for_domain(domain),
         title: "Failed SIP logins from #{e.ip}",
         message: "#{where} was banned after repeated failed logins to #{domain}.",
         data: %{ip: e.ip, port: e.port, domain: domain}
       }}
    ]
  end

  def actions(%EdgeBanned{} = e) do
    where = if e.port, do: "#{e.ip}:#{e.port}", else: e.ip

    [
      {:raise,
       %{
         kind: "sip_attack",
         key: "sip_attack",
         title: "SIP attack: #{e.reason}",
         message: "#{where} was banned (#{e.reason}).",
         data: %{ip: e.ip, port: e.port, reason: e.reason}
       }}
    ]
  end

  def actions(%EdgeAlert{ip: ip, reason: reason}),
    do: [
      {:raise,
       %{
         kind: "sip_attack",
         key: "office_ip:#{ip}",
         title: "Office IP #{ip} would have been banned",
         message:
           "#{ip} hit the #{reason} limit. It is an office address, so it was not banned; check the phones there.",
         data: %{ip: ip, reason: reason}
       }}
    ]

  def actions(%FraudAlert{blocked: true} = e),
    do: [
      {:raise,
       %{
         kind: "fraud_block",
         key: "fraud:#{e.rule}",
         tenant_id: e.tenant_id,
         title: "Outbound calls blocked: #{e.rule}",
         message:
           "A fraud rule blocked the tenant's outbound calls: #{e.detail}. A platform admin can lift the block.",
         data: %{rule: e.rule}
       }}
    ]

  def actions(%FraudAlert{} = e),
    do: [
      {:raise,
       %{
         kind: "unusual_activity",
         key: "unusual:#{e.rule}",
         tenant_id: e.tenant_id,
         title: "Unusual calling: #{e.rule}",
         message: e.detail || e.rule,
         data: %{rule: e.rule}
       }}
    ]

  def actions(%LoginAlert{kind: "new_ip"} = e),
    do: [
      {:raise,
       %{
         kind: "login_new_ip",
         key: "login_ip:#{e.account_id}:#{e.ip}",
         tenant_id: e.tenant_id,
         title: "Login from a new address",
         message:
           "Your account logged in from #{e.ip}, an address it has not used lately. If this was not you, change your password and end your other sessions.",
         data: account(e)
       }}
    ]

  def actions(%LoginAlert{kind: "failed_2fa"} = e),
    do: [
      {:raise,
       %{
         kind: "failed_2fa",
         key: "2fa:#{e.account_id}:#{System.unique_integer([:positive])}",
         tenant_id: e.tenant_id,
         title: "Wrong two-factor code",
         message:
           "Your password was right but the code was wrong, from #{e.ip}. If this was not you, change your password.",
         data: account(e)
       }}
    ]

  def actions(%LoginAlert{kind: "account_failures"} = e),
    do: [
      {:raise,
       %{
         kind: "brute_force",
         key: "portal_account:#{e.account_id}",
         tenant_id: e.tenant_id,
         title: "Failed portal logins on an account",
         message: "#{e.detail} on one portal account.",
         data: account(e)
       }}
    ]

  def actions(%LoginAlert{kind: "ip_blocked"} = e),
    do: [
      {:raise,
       %{
         kind: "brute_force",
         key: "portal_ip:#{e.ip}",
         title: "Address blocked after failed portal logins",
         message: "#{e.ip} is blocked for #{e.detail} after failed logins.",
         data: %{ip: e.ip}
       }}
    ]

  def actions(%HealthChanged{status: "ok", component: c}), do: [{:resolve, nil, "health:#{c}"}]

  # Trunks have their own alerts (TrunkStatusChanged).
  def actions(%HealthChanged{component: "trunk_registrations"}), do: []

  def actions(%HealthChanged{component: c} = e) do
    {kind, title} = health_kind(c)
    severity = if kind == "service_down" or e.status == "error", do: "critical", else: "warning"

    [
      {:raise,
       %{
         kind: kind,
         key: "health:#{c}",
         severity: severity,
         title: title,
         message: to_string(e.detail || e.status),
         data: %{component: c, status: e.status}
       }}
    ]
  end

  def actions(%TrunkStatusChanged{up: false} = t),
    do: [
      {:raise,
       %{
         kind: "trunk_down",
         key: "trunk:#{t.trunk_id}",
         tenant_id: t.tenant_id,
         title: "Trunk down: #{t.name}",
         message: "#{t.name}: #{t.reason}. Calls go to the next trunk of each route.",
         data: %{trunk_id: t.trunk_id}
       }}
    ]

  def actions(%TrunkStatusChanged{up: true} = t),
    do: [{:resolve, t.tenant_id, "trunk:#{t.trunk_id}"}]

  def actions(%UsageThresholdReached{} = u) do
    left = tenths(max(u.allowed - u.used, 0))

    severity =
      cond do
        u.percent >= 100 -> "critical"
        u.percent >= 90 -> "warning"
        true -> "info"
      end

    tail =
      if u.percent >= 100,
        do:
          "Outbound calls are refused until the period ends on #{u.period_end}, as the plan says; emergency numbers still work.",
        else:
          "#{left} minutes are left until #{u.period_end}." <>
            if(u.run_out, do: " At this month's rate they run out on #{u.run_out}.", else: "")

    [
      {:raise,
       %{
         kind: "usage_threshold",
         key: "usage:#{u.limit}:#{u.period_end}:#{u.percent}",
         tenant_id: u.tenant_id,
         severity: severity,
         title: "#{u.percent}% of outbound minutes used",
         message:
           "#{u.used} of #{u.allowed} outbound minutes used this month (#{u.percent}%). " <> tail,
         data: Map.take(u, [:limit, :percent, :used, :allowed, :period_end, :run_out])
       }}
    ]
  end

  def actions(%UsageSummary{} = u) do
    lines =
      for {dir, t} <- Enum.sort(u.totals),
          do: "#{dir}: #{t.calls} calls, #{t.answered} answered, #{t.minutes} minutes"

    [
      {:raise,
       %{
         kind: "usage_summary",
         key: "summary:#{u.month}",
         tenant_id: u.tenant_id,
         title: "Usage for #{u.month}",
         message: Enum.join(lines, "; "),
         data: %{month: u.month}
       }}
    ]
  end

  def actions(%LimitReached{} = l),
    do: [
      {:raise,
       %{
         kind: "limit_reached",
         key: "limit:#{l.limit}:#{Date.utc_today()}",
         tenant_id: l.tenant_id,
         title: "Limit reached: #{l.limit}",
         message: "A call was refused: #{l.detail || l.limit}.",
         data: %{limit: l.limit}
       }}
    ]

  def actions(%WebhookDeadLettered{} = w),
    do: [
      {:raise,
       %{
         kind: "webhook_dead",
         key: "webhook:#{w.endpoint_id}",
         tenant_id: w.tenant_id,
         title: "Webhook endpoint failing",
         message:
           "#{w.url} did not accept #{w.event_type} for 24 hours; the delivery was given up. See its delivery log.",
         data: %{endpoint_id: w.endpoint_id}
       }}
    ]

  def actions(%CallEvent{type: "missed", extension_ids: ids} = c) do
    for id <- ids,
        %Core.User{} = u <- [Core.extension_user(id)],
        do:
          {:raise,
           %{
             kind: "missed_call",
             key: "missed:#{c.call_id}:#{id}",
             tenant_id: c.tenant_id,
             user_id: u.id,
             title: "Missed call from #{c.from}",
             message: "#{c.from_name || c.from} called and nobody answered.",
             data: %{call_id: c.call_id, from: c.from}
           }}
  end

  def actions(%VoicemailReceived{} = v) do
    case Core.extension_user(v.extension_id) do
      %Core.User{} = u ->
        [
          {:raise,
           %{
             kind: "voicemail",
             key: "vm:#{v.voicemail_id}",
             tenant_id: v.tenant_id,
             user_id: u.id,
             title: "New voicemail from #{v.caller_number}",
             message: "#{v.caller_name || v.caller_number} left a #{v.duration} second message.",
             data: %{voicemail_id: v.voicemail_id}
           }}
        ]

      nil ->
        []
    end
  end

  def actions(_), do: []

  defp account(e), do: %{account_type: e.account_type, account_id: e.account_id, ip: e.ip}

  # A number of minutes to a tenth; whole numbers without ".0".
  defp tenths(v) do
    m = Float.round(v / 1, 1)
    if m == trunc(m), do: trunc(m), else: m
  end

  defp health_kind(c) when c in ~w(postgres freeswitch kamailio),
    do: {"service_down", "#{service(c)} is not answering"}

  defp health_kind("disk"), do: {"disk", "Disk space low"}
  defp health_kind("certificate"), do: {"certificate_expiring", "Certificate expiring"}
  defp health_kind("backups"), do: {"backup_failed", "Backups failing"}
  defp health_kind("oban_backlog"), do: {"queue_backlog", "Background jobs piling up"}
  defp health_kind(other), do: {"service_down", "#{other} is failing"}

  defp service("postgres"), do: "PostgreSQL"
  defp service("freeswitch"), do: "FreeSWITCH"
  defp service("kamailio"), do: "Kamailio"
end
