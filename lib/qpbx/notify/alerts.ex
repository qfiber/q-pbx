defmodule QPBX.Notify.Alerts do
  @moduledoc """
  Alerts and who hears of them.

  - `raise/1`: an alert by kind (`QPBX.Notify.Catalogue`) and key. A key that is still open
    (not resolved) is the same alert: the repeat is counted, and recipients hear of repeats at
    most every #{div(15 * 60, 60)} minutes, grouped ("37 more since 14:02").
  - `acknowledge/2`, `resolve/2`: state changes; a resolved alert tells everyone told of it
    ("back to normal"); webhooks also hear of acknowledgements.
  - Recipients: the kind's audience (platform admins, the tenant's admins, the alert's user)
    on the channels each person chose for the category (default by severity; a mandatory
    category always reaches the defaults), plus the tenant's and the platform's shared
    recipients and alert webhooks for the category and severity. A person's email carries
    warning and critical alerts (info stays in the portal). Email is held back in quiet
    hours (not for critical alerts) and beyond #{20} emails an hour to one address; the portal
    entry is always made.
  """
  import Ecto.Query
  alias QPBX.Core
  alias QPBX.Events
  alias QPBX.Events.{AlertChanged, NotificationsChanged}
  alias QPBX.Notify.{AlertEmail, AlertWebhook, Catalogue}
  alias QPBX.Notify.Alerts.{Alert, Channel, Notification, Preference, Rule}
  alias QPBX.Repo

  @group_window 15 * 60
  @open_key {:unsafe_fragment,
             "(coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'), key) WHERE state <> 'resolved'"}
  @email_cap 20

  ## Raising and changing alerts

  @doc """
  Raises (or repeats) an alert. `attrs`: `kind`, `key`, `title`, `message`, and optionally
  `tenant_id`, `user_id`, `data`, `category` and `severity` (the catalogue's otherwise).
  `{:ok, alert}`.
  """
  def raise(%{kind: kind, key: key} = attrs) do
    {category, severity, _} = Catalogue.kind(kind)
    tid = attrs[:tenant_id]

    case open_alert(tid, key) do
      nil ->
        now = DateTime.utc_now()

        row = %{
          id: Ecto.UUID.generate(),
          tenant_id: tid,
          key: key,
          kind: kind,
          category: attrs[:category] || category || "operations",
          severity: attrs[:severity] || severity,
          title: attrs.title,
          message: attrs.message,
          data: attrs[:data] || %{},
          user_id: attrs[:user_id],
          state: "open",
          count: 1,
          repeats: 0,
          notified_at: now,
          inserted_at: now,
          updated_at: now
        }

        # The partial unique index allows one unresolved alert per key: a concurrent raise of
        # the same key loses here and becomes a repeat.
        case Repo.insert_all(Alert, [row],
               on_conflict: :nothing,
               conflict_target: @open_key,
               returning: true
             ) do
          {1, [alert]} -> {:ok, announce(alert, "raised")}
          {0, _} -> repeat(open_alert(tid, key), attrs)
        end

      alert ->
        repeat(alert, attrs)
    end
  end

  defp repeat(alert, attrs) do
    now = DateTime.utc_now()

    {1, [alert]} =
      Repo.update_all(
        from(a in Alert, where: a.id == ^alert.id, select: a),
        inc: [count: 1, repeats: 1],
        set: [message: attrs.message, data: attrs[:data] || alert.data, updated_at: now]
      )

    if DateTime.diff(now, alert.notified_at) >= @group_window do
      {1, [alert]} =
        Repo.update_all(from(a in Alert, where: a.id == ^alert.id, select: a),
          set: [repeats: 0, notified_at: now]
        )

      # The notice says how many repeats since the last one, and since when.
      {:ok, announce(%{alert | repeats: alert.repeats}, "repeated")}
    else
      {:ok, alert}
    end
  end

  defp open_alert(nil, key),
    do:
      Repo.one(
        from a in Alert, where: is_nil(a.tenant_id) and a.key == ^key and a.state != "resolved"
      )

  defp open_alert(tid, key),
    do:
      Repo.one(
        from a in Alert, where: a.tenant_id == ^tid and a.key == ^key and a.state != "resolved"
      )

  @doc "Acknowledges an open alert (`by`: who, as text). `{:ok, alert}` or `{:error, :not_open}`."
  def acknowledge(%Alert{state: "open"} = alert, by) do
    alert =
      alert
      |> Ecto.Changeset.change(state: "acknowledged", acknowledged_at: now(), acknowledged_by: by)
      |> Repo.update!()

    {:ok, announce(alert, "acknowledged")}
  end

  def acknowledge(%Alert{}, _by), do: {:error, :not_open}

  @doc "Resolves an alert; everyone told of it hears it is back to normal."
  def resolve(%Alert{state: state} = alert, _by) when state != "resolved" do
    alert =
      alert |> Ecto.Changeset.change(state: "resolved", resolved_at: now()) |> Repo.update!()

    {:ok, announce(alert, "resolved")}
  end

  def resolve(%Alert{}, _by), do: {:error, :not_open}

  @doc "Resolves the open alert with this key, if any (sources: the problem went away)."
  def resolve_key(tenant_id, key) do
    case open_alert(tenant_id, key) do
      nil -> :ok
      alert -> with({:ok, _} <- resolve(alert, "system"), do: :ok)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  ## Telling people

  defp announce(alert, event) do
    Events.publish(%AlertChanged{
      alert_id: alert.id,
      tenant_id: alert.tenant_id,
      event: event,
      kind: alert.kind,
      category: alert.category,
      severity: alert.severity,
      at: DateTime.utc_now()
    })

    deliver(alert, event)
    alert
  end

  @doc false
  # Every notification for one alert event: people, shared recipients, webhooks.
  def deliver(alert, event) do
    people = if event == "acknowledged", do: [], else: people(alert)
    mandatory = mandatory?(alert.category)

    for person <- people,
        channel <- channels(person, alert, mandatory),
        do: notify_person(alert, event, person, channel)

    for ch <- shared(alert),
        event != "acknowledged" or ch.kind == "webhook",
        do: notify_channel(alert, event, ch)

    :ok
  end

  defp people(%Alert{kind: kind, tenant_id: tid, user_id: uid}) do
    {_, _, audience} = Catalogue.kind(kind)

    audience
    |> Enum.flat_map(fn
      :platform_admins ->
        Enum.map(Core.list_platform_admins(), &person("platform_admin", &1, nil))

      :tenant_admins when is_binary(tid) ->
        tenant_admins(tid)

      :user when is_binary(uid) ->
        uid |> Core.get_user() |> List.wrap() |> Enum.map(&person("user", &1, &1.tenant_id))

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp tenant_admins(tid) do
    for u <- Core.list_users(%Core.Scope{kind: :platform}, %Core.Tenant{id: tid}),
        Core.User.role(u) == "tenant_admin",
        do: person("user", u, tid)
  end

  defp person(type, account, tid),
    do: %{
      type: type,
      id: account.id,
      email: account.email,
      locale: account.locale,
      tenant_id: tid
    }

  # The person's channels for the category (default by severity); quiet hours and the cap
  # are applied when sending.
  defp channels(person, alert, mandatory) do
    pref = preference(person.type, person.id)
    defaults = Catalogue.default_channels()
    chosen = (pref && Map.get(pref.channels, alert.category)) || defaults
    chosen = if mandatory, do: Enum.uniq(chosen ++ defaults), else: chosen
    if Catalogue.person_email?(alert.severity), do: chosen, else: chosen -- ["email"]
  end

  defp shared(%Alert{tenant_id: tid} = alert) do
    q = from c in Channel, where: c.enabled and ^alert.category in c.categories

    q =
      if tid,
        do: where(q, [c], c.tenant_id == ^tid or is_nil(c.tenant_id)),
        else: where(q, [c], is_nil(c.tenant_id))

    q |> Repo.all() |> Enum.filter(&Catalogue.at_least?(alert.severity, &1.min_severity))
  end

  defp notify_person(alert, event, person, "portal") do
    insert(%Notification{
      tenant_id: person.tenant_id,
      alert_id: alert.id,
      event: event,
      channel: "portal",
      account_type: person.type,
      account_id: person.id,
      status: "sent"
    })

    Events.publish(%NotificationsChanged{
      account_type: person.type,
      account_id: person.id,
      at: DateTime.utc_now()
    })
  end

  defp notify_person(alert, event, person, "email") do
    base = %Notification{
      tenant_id: person.tenant_id,
      alert_id: alert.id,
      event: event,
      channel: "email",
      account_type: person.type,
      account_id: person.id,
      address: person.email
    }

    case hold_back(alert, person, person.email) do
      nil -> email(base, person.locale)
      reason -> insert(%{base | status: "skipped", reason: reason})
    end
  end

  defp notify_person(_, _, _, _), do: :ok

  defp notify_channel(alert, event, %Channel{kind: "email"} = ch) do
    base = %Notification{
      tenant_id: alert.tenant_id,
      alert_id: alert.id,
      event: event,
      channel: "email",
      alert_channel_id: ch.id,
      address: ch.address
    }

    if over_cap?(ch.address),
      do: insert(%{base | status: "skipped", reason: "rate_cap"}),
      else: email(base, "en")
  end

  defp notify_channel(alert, event, %Channel{kind: "webhook"} = ch) do
    if ch.format == "alertmanager" and event == "acknowledged" do
      :ok
    else
      n =
        insert(%Notification{
          tenant_id: alert.tenant_id,
          alert_id: alert.id,
          event: event,
          channel: "webhook",
          alert_channel_id: ch.id,
          address: ch.address
        })

      {:ok, _} = Oban.insert(AlertWebhook.new(%{"notification_id" => n.id}))
    end
  end

  # An email with its own acknowledge link (the token is only in the email).
  defp email(base, locale) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    n = insert(%{base | ack_token_hash: :crypto.hash(:sha256, token)})

    {:ok, _} =
      Oban.insert(
        AlertEmail.new(%{"notification_id" => n.id, "token" => token, "locale" => locale || "en"})
      )

    n
  end

  defp hold_back(alert, person, address) do
    cond do
      alert.severity != "critical" and quiet?(person) -> "quiet_hours"
      over_cap?(address) -> "rate_cap"
      true -> nil
    end
  end

  defp quiet?(person) do
    with %Preference{quiet_start: a, quiet_end: b} = pref
         when is_integer(a) and is_integer(b) and a != b <- preference(person.type, person.id),
         {:ok, local} <- DateTime.now(pref.timezone || tenant_zone(person.tenant_id)) do
      h = local.hour
      if a < b, do: h >= a and h < b, else: h >= a or h < b
    else
      _ -> false
    end
  end

  defp tenant_zone(nil), do: "Etc/UTC"
  defp tenant_zone(tid), do: Core.get_tenant!(tid).timezone

  defp over_cap?(address) do
    since = DateTime.add(DateTime.utc_now(), -3600)

    Repo.aggregate(
      from(n in Notification,
        where:
          n.channel == "email" and n.address == ^address and n.inserted_at > ^since and
            n.status in ["pending", "sent"]
      ),
      :count
    ) >= @email_cap
  end

  defp insert(n), do: Repo.insert!(n)

  ## Preferences and rules

  def preference(type, id), do: Repo.get_by(Preference, account_type: type, account_id: id)

  def mandatory?(category), do: match?(%Rule{mandatory: true}, Repo.get(Rule, category))

  def mandatory_categories, do: Repo.all(from r in Rule, where: r.mandatory, select: r.category)

  @doc "Sets which categories are mandatory (platform admins)."
  def set_mandatory(categories) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for c <- Catalogue.categories(),
          do: %{category: c, mandatory: c in categories, inserted_at: now, updated_at: now}

    Repo.insert_all(Rule, rows,
      on_conflict: {:replace, [:mandatory, :updated_at]},
      conflict_target: :category
    )

    :ok
  end

  def save_preference(type, id, tenant_id, attrs) do
    (preference(type, id) || %Preference{account_type: type, account_id: id, tenant_id: tenant_id})
    |> Preference.changeset(attrs)
    |> Repo.insert_or_update()
  end
end
