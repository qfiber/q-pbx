defmodule QPBX.Web.Api.EventChannel do
  @moduledoc """
  The `events` channel: join with `{"types": [...]}` (optional; event types as webhooks name
  them, default every type) and receive `"event"` pushes, each the same JSON as a webhook body
  (`id`, `type`, `version`, `created_at`, `tenant_id`, `data`). Only the key's tenant's events.
  """
  use Phoenix.Channel
  alias QPBX.{Core, Integrations}

  @recheck_ms 60_000

  @impl true
  def join("events", params, socket) do
    known = Integrations.webhook_event_types()

    case params["types"] || known do
      types when is_list(types) and types != [] -> join_types(types, types -- known, socket)
      _ -> {:error, %{reason: "bad_types"}}
    end
  end

  defp join_types(types, [], socket) do
    for source <- Integrations.event_sources(), do: QPBX.Events.subscribe(source)
    Process.send_after(self(), :recheck, @recheck_ms)
    {:ok, %{types: types}, assign(socket, types: MapSet.new(types))}
  end

  defp join_types(_types, unknown, _socket),
    do: {:error, %{reason: "unknown_types", types: unknown}}

  @impl true
  def handle_info({:event, event}, socket) do
    case Integrations.event_message(event) do
      {tid, type, message} when tid == socket.assigns.tenant_id ->
        if MapSet.member?(socket.assigns.types, type), do: push(socket, "event", message)

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  # An expired or deleted key ends the stream (revocation closes it at once, see EventSocket).
  def handle_info(:recheck, socket) do
    case Core.authenticate_api_key(socket.assigns.token) do
      {:ok, _} ->
        Process.send_after(self(), :recheck, @recheck_ms)
        {:noreply, socket}

      _ ->
        {:stop, :normal, socket}
    end
  end
end
