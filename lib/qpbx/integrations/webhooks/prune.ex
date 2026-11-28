defmodule QPBX.Integrations.Webhooks.Prune do
  @moduledoc "Oban worker, daily (cron): deletes webhook deliveries older than 30 days."
  use Oban.Worker, queue: :webhooks, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    {:ok, _} = QPBX.Integrations.Webhooks.prune(30)
    :ok
  end
end
