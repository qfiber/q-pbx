defmodule QPBX.Notify.Inbox do
  @moduledoc """
  The notification service as people and programs use it: alerts of a scope (a tenant's own;
  the platform sees all), a person's portal notifications and bell count, their preferences,
  a scope's shared recipients and alert webhooks, the delivery log and resend, the test
  notification. Tenant scopes run under row-level security.
  """
  import Ecto.Query
  alias QPBX.Core
  alias QPBX.Core.{PlatformAdmin, Scope, User}
  alias QPBX.Events
  alias QPBX.Events.NotificationsChanged
  alias QPBX.Integrations.Webhooks.Signature
  alias QPBX.Notify.{AlertEmail, Alerts, AlertWebhook}
  alias QPBX.Notify.Alerts.{Alert, Channel, Notification}
  alias QPBX.Repo

  ## Alerts

  @doc "A scope's alerts, newest first. Filters: `state`, `category`, `severity`; `limit`."
  def alerts(%Scope{} = scope, filters \\ %{}, limit \\ 100) do
    q = from a in Alert, order_by: [desc: a.inserted_at], limit: ^limit
    q = Enum.reduce(~w(state category severity), q, fn f, q -> filter(q, f, filters[f]) end)
    run(scope, fn -> Repo.all(own(q, scope)) end)
  end

  defp filter(q, _f, v) when v in [nil, ""], do: q
  defp filter(q, "state", v), do: where(q, [a], a.state == ^v)
  defp filter(q, "category", v), do: where(q, [a], a.category == ^v)
  defp filter(q, "severity", v), do: where(q, [a], a.severity == ^v)

  def alert(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        run(scope, fn -> Repo.one(own(from(a in Alert, where: a.id == ^id), scope)) end)

      :error ->
        nil
    end
  end

  def acknowledge(%Scope{} = scope, id, actor),
    do: with_alert(scope, id, &Alerts.acknowledge(&1, who(actor)))

  def resolve(%Scope{} = scope, id, actor),
    do: with_alert(scope, id, &Alerts.resolve(&1, who(actor)))

  defp with_alert(scope, id, fun) do
    case alert(scope, id) do
      nil -> {:error, :not_found}
      a -> fun.(a)
    end
  end

  @doc "Acknowledges through an email link (`<notification id>.<token>`): `{:ok, alert}` or `{:error, _}`."
  def acknowledge_by_token(link) when is_binary(link) do
    with [id, token] <- String.split(link, ".", parts: 2),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Notification{ack_token_hash: hash} = n when is_binary(hash) <-
           Repo.get(Notification, id),
         true <- Plug.Crypto.secure_compare(hash, :crypto.hash(:sha256, token)),
         %Alert{} = alert <- Repo.get(Alert, n.alert_id) do
      case Alerts.acknowledge(alert, "email: " <> (n.address || "")) do
        {:error, :not_open} -> {:ok, alert}
        ok -> ok
      end
    else
      _ -> {:error, :invalid}
    end
  end

  def acknowledge_by_token(_), do: {:error, :invalid}

  @doc "Sends a test notification to the scope's people and channels for `category`."
  def send_test(%Scope{} = scope, category, actor) do
    Alerts.raise(%{
      kind: "test",
      key: "test:" <> Ecto.UUID.generate(),
      category: category,
      tenant_id: scope.tenant_id,
      title: "Test notification",
      message: "This is a test notification from Q-PBX, sent by #{who(actor)}.",
      data: %{}
    })
  end

  ## A person's notifications (the bell)

  def notifications(account, limit \\ 50) do
    {type, id} = ref(account)

    Repo.all(
      from n in Notification,
        where: n.account_type == ^type and n.account_id == ^id and n.channel == "portal",
        order_by: [desc: n.inserted_at],
        limit: ^limit,
        preload: :alert
    )
  end

  def unread_count(account) do
    {type, id} = ref(account)

    Repo.aggregate(
      from(n in Notification,
        where:
          n.account_type == ^type and n.account_id == ^id and n.channel == "portal" and
            is_nil(n.read_at)
      ),
      :count
    )
  end

  @doc "Marks one of the person's notifications read, or all of them (`:all`)."
  def mark_read(account, which) do
    {type, id} = ref(account)

    q =
      from n in Notification,
        where:
          n.account_type == ^type and n.account_id == ^id and n.channel == "portal" and
            is_nil(n.read_at)

    q = if which == :all, do: q, else: where(q, [n], n.id == ^which)
    Repo.update_all(q, set: [read_at: DateTime.utc_now() |> DateTime.truncate(:second)])

    Events.publish(%NotificationsChanged{
      account_type: type,
      account_id: id,
      at: DateTime.utc_now()
    })

    :ok
  end

  def preference(account) do
    {type, id} = ref(account)
    Alerts.preference(type, id)
  end

  def save_preference(account, attrs) do
    {type, id} = ref(account)
    Alerts.save_preference(type, id, Map.get(account, :tenant_id), attrs)
  end

  ## Shared recipients and alert webhooks

  def channels(%Scope{} = scope),
    do: run(scope, fn -> Repo.all(from(c in Channel, order_by: c.inserted_at) |> own(scope)) end)

  def change_channel(%Channel{} = ch \\ %Channel{}, attrs \\ %{}),
    do: Channel.changeset(ch, attrs)

  @doc "Adds a shared recipient or an alert webhook: `{:ok, channel, secret}` (webhooks: the signing secret, shown once; email: nil)."
  def create_channel(%Scope{} = scope, attrs, actor) do
    secret = Signature.new_secret()

    cs =
      %Channel{tenant_id: scope.tenant_id, secret: secret}
      |> Channel.changeset(attrs)
      |> check_url()

    run(scope, fn ->
      with {:ok, ch} <- Repo.insert(cs) do
        {:ok, _} =
          Core.audit(actor, "alert_channel.create", ch, %{kind: ch.kind, address: ch.address})

        {:ok, ch}
      end
    end)
    |> case do
      {:ok, %Channel{kind: "webhook"} = ch} -> {:ok, ch, secret}
      {:ok, ch} -> {:ok, ch, nil}
      error -> error
    end
  end

  def update_channel(%Scope{} = scope, id, attrs, actor) do
    with %Channel{} = ch <- channel(scope, id) || {:error, :not_found} do
      cs = ch |> Channel.changeset(Map.drop(attrs, ["kind", :kind])) |> check_url()
      run(scope, fn -> save_channel(cs, actor) end)
    end
  end

  defp save_channel(cs, actor) do
    with {:ok, ch} <- Repo.update(cs) do
      {:ok, _} = Core.audit(actor, "alert_channel.update", ch, cs.changes)
      {:ok, ch}
    end
  end

  def delete_channel(%Scope{} = scope, id, actor) do
    with %Channel{} = ch <- channel(scope, id) || {:error, :not_found} do
      run(scope, fn ->
        Repo.delete!(ch)
        {:ok, _} = Core.audit(actor, "alert_channel.delete", ch, %{address: ch.address})
        {:ok, ch}
      end)
    end
  end

  defp channel(scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        run(scope, fn -> Repo.one(own(from(c in Channel, where: c.id == ^id), scope)) end)

      :error ->
        nil
    end
  end

  # A webhook's address is checked like event webhooks' (HTTPS, a public address).
  defp check_url(%Ecto.Changeset{valid?: true, changes: %{address: url}} = cs) do
    if Ecto.Changeset.get_field(cs, :kind) == "webhook" do
      case QPBX.Integrations.check_destination(url) do
        :ok ->
          cs

        {:error, {:blocked_address, _}} ->
          Ecto.Changeset.add_error(cs, :address, "points to an internal address")

        {:error, :nxdomain} ->
          Ecto.Changeset.add_error(cs, :address, "has a host name that does not resolve")

        {:error, _} ->
          Ecto.Changeset.add_error(cs, :address, "is not a valid URL")
      end
    else
      cs
    end
  end

  defp check_url(cs), do: cs

  ## Delivery log

  @doc "Every notification of one of the scope's alerts (people and channels), newest first."
  def deliveries(%Scope{} = scope, alert_id) do
    case alert(scope, alert_id) do
      nil ->
        []

      a ->
        Repo.all(
          from n in Notification, where: n.alert_id == ^a.id, order_by: [desc: n.inserted_at]
        )
    end
  end

  @doc "Sends one email or webhook notification again (a new notification, same alert and event)."
  def resend(%Scope{} = scope, notification_id, actor) do
    with {:ok, nid} <- Ecto.UUID.cast(notification_id),
         %Notification{channel: ch} = n when ch in ["email", "webhook"] <-
           Repo.get(Notification, nid),
         %Alert{} <- alert(scope, n.alert_id) do
      copy =
        Repo.insert!(%{
          n
          | id: nil,
            status: "pending",
            reason: nil,
            attempts: [],
            inserted_at: nil,
            updated_at: nil,
            ack_token_hash: nil,
            read_at: nil
        })

      {:ok, _} =
        Core.audit(actor, "notification.resend", nil, %{
          tenant_id: n.tenant_id,
          notification_id: n.id
        })

      enqueue(copy)
      {:ok, copy}
    else
      _ -> {:error, :not_found}
    end
  end

  defp enqueue(%Notification{channel: "webhook"} = n),
    do: {:ok, _} = Oban.insert(AlertWebhook.new(%{"notification_id" => n.id}))

  defp enqueue(%Notification{channel: "email"} = n) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    n |> Ecto.Changeset.change(ack_token_hash: :crypto.hash(:sha256, token)) |> Repo.update!()

    {:ok, _} =
      Oban.insert(
        AlertEmail.new(%{"notification_id" => n.id, "token" => token, "locale" => "en"})
      )
  end

  ## Mandatory categories (platform admins)

  def mandatory_categories, do: Alerts.mandatory_categories()

  def set_mandatory(%Scope{kind: :platform}, categories, actor) do
    :ok = Alerts.set_mandatory(categories)
    {:ok, _} = Core.audit(actor, "alert_rules.mandatory", nil, %{categories: categories})
    :ok
  end

  ## Helpers

  # A tenant sees its own rows; the platform its own and every tenant's (alerts) or its own
  # (channels).
  defp own(q, %Scope{kind: :tenant, tenant_id: tid}), do: where(q, [x], x.tenant_id == ^tid)

  defp own(%Ecto.Query{from: %{source: {"alert_channels", _}}} = q, %Scope{kind: :platform}),
    do: where(q, [x], is_nil(x.tenant_id))

  defp own(q, %Scope{kind: :platform}), do: q

  defp run(%Scope{} = scope, fun), do: Scope.run(scope, fun)

  defp ref(%User{id: id}), do: {"user", id}
  defp ref(%PlatformAdmin{id: id}), do: {"platform_admin", id}

  defp who(%{email: email}) when is_binary(email), do: email
  defp who(%Core.ApiKey{name: name}), do: "API key " <> name
  defp who({:system, name}), do: name
  defp who(_), do: "someone"
end
