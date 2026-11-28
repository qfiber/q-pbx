defmodule QPBX.Notify do
  @moduledoc """
  Public API of the notify area: account emails (setup link, voicemail) and the notification
  service (alerts, notifications, preferences, shared recipients and alert webhooks).
  See `lib/qpbx/notify/README.md`.
  """
  use Boundary,
    deps: [QPBX.Storage, QPBX.Repo, QPBX.Core, QPBX.Events, QPBX.Integrations],
    exports: [Catalogue, Alerts.Alert, Alerts.Notification, Alerts.Channel, Alerts.Preference]

  alias QPBX.Notify.{SetupLinkEmail, VoicemailEmail}

  @doc """
  Queues the setup-link email (Oban queue `notify`). `account` needs `email`, `name` and
  `locale` (nil falls back to English).
  """
  def deliver_setup_link(%{email: email, name: name} = account, url) when is_binary(url) do
    %{
      "email" => email,
      "name" => name,
      "locale" => Map.get(account, :locale) || "en",
      "url" => url
    }
    |> SetupLinkEmail.new()
    |> Oban.insert()
  end

  @doc """
  Queues the email for a new voicemail. `vm`: email, locale, extension, caller, caller_name,
  duration, at, format, and file_key (nil: no audio attached).
  """
  def deliver_voicemail(%{email: email} = vm) when is_binary(email) do
    vm
    |> Map.take([
      :email,
      :locale,
      :extension,
      :caller,
      :caller_name,
      :duration,
      :format,
      :file_key
    ])
    |> Map.put(:at, vm.at |> DateTime.truncate(:second) |> DateTime.to_iso8601())
    |> VoicemailEmail.new()
    |> Oban.insert()
  end

  ## Alerts (QPBX.Notify.Alerts) and the service around them (QPBX.Notify.Inbox)

  alias QPBX.Notify.{Alerts, Inbox}

  @doc "Raises or repeats an alert (sources): see `QPBX.Notify.Alerts.raise/1`."
  defdelegate raise_alert(attrs), to: Alerts, as: :raise
  @doc "Resolves the open alert with this key, if any (the problem went away)."
  defdelegate resolve_alert_key(tenant_id, key), to: Alerts, as: :resolve_key

  defdelegate list_alerts(scope, filters \\ %{}, limit \\ 100), to: Inbox, as: :alerts
  defdelegate get_alert(scope, id), to: Inbox, as: :alert
  defdelegate acknowledge_alert(scope, id, actor), to: Inbox, as: :acknowledge
  defdelegate resolve_alert(scope, id, actor), to: Inbox, as: :resolve
  defdelegate acknowledge_by_token(link), to: Inbox
  defdelegate send_test_notification(scope, category, actor), to: Inbox, as: :send_test
  defdelegate list_notifications(account, limit \\ 50), to: Inbox, as: :notifications
  defdelegate unread_count(account), to: Inbox
  defdelegate mark_read(account, which), to: Inbox
  defdelegate my_preference(account), to: Inbox, as: :preference
  defdelegate save_my_preference(account, attrs), to: Inbox, as: :save_preference
  defdelegate list_alert_channels(scope), to: Inbox, as: :channels

  defdelegate change_alert_channel(channel \\ %QPBX.Notify.Alerts.Channel{}, attrs \\ %{}),
    to: Inbox,
    as: :change_channel

  @doc "Adds a shared recipient or alert webhook: `{:ok, channel, secret}` (secret: webhooks only, shown once)."
  defdelegate create_alert_channel(scope, attrs, actor), to: Inbox, as: :create_channel
  defdelegate update_alert_channel(scope, id, attrs, actor), to: Inbox, as: :update_channel
  defdelegate delete_alert_channel(scope, id, actor), to: Inbox, as: :delete_channel
  defdelegate list_alert_deliveries(scope, alert_id), to: Inbox, as: :deliveries
  defdelegate resend_notification(scope, notification_id, actor), to: Inbox, as: :resend
  defdelegate mandatory_categories(), to: Inbox
  defdelegate set_mandatory_categories(scope, categories, actor), to: Inbox, as: :set_mandatory
end
