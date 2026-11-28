defmodule QPBX.Notify.AlertWebhook do
  @moduledoc """
  Oban worker (queue `notify`): one alert sent to an alert webhook, signed like event webhooks
  (`x-qpbx-signature`) and retried the same way (30 s doubling to 6 h apart, for 24 hours,
  then dead). Generic format: `{"type": "alert.raised" | "alert.acknowledged" |
  "alert.resolved", "id", "created_at", "alert": {...}}`. `alertmanager` format: Alertmanager's
  webhook body (status firing or resolved), which Alertmanager-style receivers (PagerDuty,
  Opsgenie and others) accept.
  """
  use Oban.Worker, queue: :notify, max_attempts: 20
  import Ecto.Query
  alias QPBX.Integrations
  alias QPBX.Integrations.Webhooks.Signature
  alias QPBX.Notify.Alerts.{Alert, Channel, Notification}
  alias QPBX.Repo

  @give_up_after 24 * 3600

  def pause(n), do: min(30 * Integer.pow(2, n - 1), 6 * 3600)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: n}), do: pause(n)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"notification_id" => id}, attempt: n, max_attempts: max}) do
    with %Notification{status: s} = note when s in ["pending", "failed"] <-
           Repo.get(Notification, id),
         %Channel{enabled: true} = ch <- Repo.get(Channel, note.alert_channel_id),
         %Alert{} = alert <- Repo.get(Alert, note.alert_id) do
      send_it(note, ch, alert, n, max)
    else
      _ -> :ok
    end
  end

  defp send_it(note, ch, alert, n, max) do
    body = Jason.encode!(payload(ch.format, note, alert))
    ts = System.os_time(:second)

    headers = [
      {"content-type", "application/json"},
      {"x-qpbx-event-id", note.id},
      {"x-qpbx-timestamp", Integer.to_string(ts)},
      {"x-qpbx-signature", Signature.sign(ch.secret, ts, body)}
    ]

    started = System.monotonic_time(:millisecond)
    result = Integrations.request(:post, ch.address, headers: headers, body: body)

    log = %{
      "at" => DateTime.utc_now(),
      "duration_ms" => System.monotonic_time(:millisecond) - started
    }

    case result do
      {:ok, %{status: s}} when s in 200..299 ->
        mark(note, "sent", Map.put(log, "status", s))
        :ok

      other ->
        log = Map.merge(log, outcome(other))

        if n >= max or
             DateTime.diff(DateTime.utc_now(), note.inserted_at) + pause(n) > @give_up_after do
          mark(note, "dead", log)
          {:cancel, :dead}
        else
          mark(note, "failed", log)
          {:error, log["error"] || "HTTP #{log["status"]}"}
        end
    end
  end

  defp outcome({:ok, %{status: s}}), do: %{"status" => s}

  defp outcome({:error, {:blocked_address, ip}}),
    do: %{"error" => "refused: #{ip} is an internal address"}

  defp outcome({:error, reason}), do: %{"error" => reason |> inspect() |> String.slice(0, 300)}

  defp mark(n, status, attempt),
    do:
      Repo.update_all(from(x in Notification, where: x.id == ^n.id),
        set: [status: status, updated_at: DateTime.utc_now()],
        push: [attempts: attempt]
      )

  @doc false
  def payload("alertmanager", _note, a) do
    status = if a.state == "resolved", do: "resolved", else: "firing"

    labels = %{
      alertname: a.kind,
      severity: a.severity,
      category: a.category,
      tenant_id: a.tenant_id || "platform"
    }

    %{
      version: "4",
      groupKey: a.key,
      status: status,
      receiver: "qpbx",
      groupLabels: %{alertname: a.kind},
      commonLabels: labels,
      commonAnnotations: %{summary: a.title, description: a.message},
      externalURL: portal_url(),
      alerts: [
        %{
          status: status,
          labels: labels,
          annotations: %{summary: a.title, description: a.message},
          startsAt: a.inserted_at,
          endsAt: a.resolved_at || "0001-01-01T00:00:00Z",
          generatorURL: portal_url(),
          fingerprint: a.id
        }
      ]
    }
  end

  def payload(_generic, note, a) do
    %{
      type: "alert." <> if(note.event == "repeated", do: "raised", else: note.event),
      id: note.id,
      created_at: note.inserted_at,
      alert: %{
        id: a.id,
        key: a.key,
        kind: a.kind,
        category: a.category,
        severity: a.severity,
        state: a.state,
        tenant_id: a.tenant_id,
        title: a.title,
        message: a.message,
        data: a.data,
        count: a.count,
        raised_at: a.inserted_at,
        link: portal_url()
      }
    }
  end

  defp portal_url, do: Application.get_env(:qpbx, :portal_url, "http://localhost:4000")
end
