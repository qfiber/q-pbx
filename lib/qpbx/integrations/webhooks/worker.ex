defmodule QPBX.Integrations.Webhooks.Worker do
  @moduledoc """
  Oban worker (queue `webhooks`): one attempt at a delivery. A 2xx answer delivers it; anything
  else is retried with growing pauses (30 s, 1, 2, 4 ... minutes, at most 6 hours apart) until
  24 hours have passed, then the delivery is dead and `WebhookDeadLettered` is published.
  Each attempt is signed afresh (its own timestamp) and logged on the delivery.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 20

  import Ecto.Query
  alias QPBX.Events
  alias QPBX.Events.WebhookDeadLettered
  alias QPBX.Integrations.OutboundHTTP
  alias QPBX.Integrations.Webhooks.{Delivery, Endpoint, Signature}
  alias QPBX.Repo

  @give_up_after 24 * 3600
  @keep_response 2_000

  @doc "Seconds before attempt `n + 1` after attempt `n` failed."
  def pause(n), do: min(30 * Integer.pow(2, n - 1), 6 * 3600)

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: n}), do: pause(n)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}, attempt: n, max_attempts: max}) do
    with %Delivery{status: "pending"} = d <- Repo.get(Delivery, id),
         %Endpoint{enabled: true} = e <- Repo.get(Endpoint, d.endpoint_id) do
      attempt(d, e, n, max)
    else
      # Delivered or dead already, or the endpoint was removed or turned off.
      _ -> :ok
    end
  end

  defp attempt(d, e, n, max) do
    ts = System.os_time(:second)
    started = System.monotonic_time(:millisecond)

    headers = [
      {"content-type", "application/json"},
      {"x-qpbx-event-id", d.event_id},
      {"x-qpbx-event-type", d.event_type},
      {"x-qpbx-timestamp", Integer.to_string(ts)},
      {"x-qpbx-signature", Signature.sign(e.secret, ts, d.payload)}
    ]

    result = OutboundHTTP.request(:post, e.url, headers: headers, body: d.payload)
    log = entry(result, started)

    case result do
      {:ok, %{status: s}} when s in 200..299 ->
        save(d, "delivered", log, DateTime.utc_now())
        :ok

      _ ->
        if n >= max or
             DateTime.diff(DateTime.utc_now(), d.inserted_at) + pause(n) > @give_up_after do
          save(d, "dead", log, nil)

          Events.publish(%WebhookDeadLettered{
            tenant_id: d.tenant_id,
            endpoint_id: d.endpoint_id,
            delivery_id: d.id,
            event_type: d.event_type,
            url: e.url,
            at: DateTime.utc_now()
          })

          {:cancel, :dead}
        else
          save(d, "pending", log, nil)
          {:error, log["error"] || "HTTP #{log["status"]}"}
        end
    end
  end

  defp entry(result, started) do
    base = %{
      "at" => DateTime.utc_now(),
      "duration_ms" => System.monotonic_time(:millisecond) - started
    }

    case result do
      {:ok, %{status: s, body: b}} ->
        Map.merge(base, %{"status" => s, "response" => String.slice(utf8(b), 0, @keep_response)})

      {:error, reason} ->
        Map.merge(base, %{"status" => nil, "error" => error_text(reason)})
    end
  end

  defp utf8(b), do: if(String.valid?(b), do: b, else: "(binary response)")

  defp error_text({:blocked_address, ip}), do: "refused: #{ip} is an internal address"

  defp error_text({:connect, %{reason: r}}),
    do: "connection failed: #{inspect(r)}" |> String.slice(0, 300)

  defp error_text(reason), do: reason |> inspect() |> String.slice(0, 300)

  defp save(d, status, log, delivered_at) do
    Repo.update_all(from(x in Delivery, where: x.id == ^d.id),
      set: [status: status, delivered_at: delivered_at, updated_at: DateTime.utc_now()],
      push: [attempts: log]
    )
  end
end
