defmodule QPBX.Notify.AlertEmail do
  @moduledoc """
  Oban worker (queue `notify`): one alert email, in the recipient's language, with a link to
  acknowledge it (raised and repeated) or saying it is back to normal (resolved). A permanent
  SMTP refusal (a hard bounce) marks the notification bounced and is not retried.
  """
  use Oban.Worker, queue: :notify, max_attempts: 10
  use Gettext, backend: QPBX.Notify.Gettext
  import Swoosh.Email
  require Ecto.Query
  alias QPBX.Notify.Alerts.{Alert, Notification}
  alias QPBX.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"notification_id" => id, "token" => token, "locale" => locale}}) do
    with %Notification{status: s} = n when s in ["pending", "failed"] <-
           Repo.get(Notification, id),
         %Alert{} = alert <- Repo.get(Alert, n.alert_id) do
      email = Gettext.with_locale(QPBX.Notify.Gettext, locale, fn -> build(n, alert, token) end)

      sent(n, QPBX.Notify.Mailer.deliver(email))
    else
      _ -> :ok
    end
  end

  defp sent(n, {:ok, _}) do
    mark(n, "sent", %{"at" => DateTime.utc_now(), "result" => "sent"})
    :ok
  end

  defp sent(n, {:error, reason}) do
    status = if bounce?(reason), do: "bounced", else: "failed"

    mark(n, status, %{
      "at" => DateTime.utc_now(),
      "error" => String.slice(inspect(reason), 0, 300)
    })

    if status == "bounced", do: {:cancel, :bounced}, else: {:error, reason}
  end

  # gen_smtp reports a 5xx answer (no such mailbox, refused) as a permanent failure.
  defp bounce?(reason), do: inspect(reason) =~ "permanent_failure"

  defp mark(n, status, attempt),
    do:
      Repo.update_all(Ecto.Query.from(x in Notification, where: x.id == ^n.id),
        set: [status: status, updated_at: DateTime.utc_now()],
        push: [attempts: attempt]
      )

  @doc false
  def build(n, alert, token) do
    {subject, lines} = text(n.event, alert)
    link = portal_url() <> "/alerts/ack/" <> n.id <> "." <> token

    lines =
      if n.event in ["raised", "repeated"] and alert.state == "open",
        do: lines ++ ["", gettext("Acknowledge: %{link}", link: link)],
        else: lines

    new()
    |> to(n.address)
    |> from(Application.get_env(:qpbx, :mail_from, {"Q-PBX", "noreply@localhost"}))
    |> subject(subject)
    |> text_body(
      Enum.join(
        lines ++
          ["", gettext("Your notification settings are in the portal: %{url}", url: portal_url())],
        "\n"
      )
    )
  end

  defp text("resolved", a),
    do:
      {gettext("Back to normal: %{title}", title: a.title),
       [gettext("This alert is resolved: %{title}", title: a.title)]}

  defp text("repeated", a),
    do:
      {"[#{severity(a.severity)}] #{a.title}",
       [
         a.message,
         "",
         gettext("%{count} more since %{time} (UTC).",
           count: a.repeats,
           time: Calendar.strftime(a.notified_at, "%H:%M")
         )
       ]}

  defp text(_, a), do: {"[#{severity(a.severity)}] #{a.title}", [a.message]}

  defp severity("critical"), do: gettext("Critical")
  defp severity("warning"), do: gettext("Warning")
  defp severity(_), do: gettext("Info")

  defp portal_url, do: Application.get_env(:qpbx, :portal_url, "http://localhost:4000")
end
