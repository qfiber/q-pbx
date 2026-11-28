defmodule QPBX.Web.Api.WebhookController do
  @moduledoc "Webhook endpoints and their delivery log (tenant keys with the admin scope)."
  use QPBX.Web, :api_controller
  alias QPBX.Integrations
  alias QPBX.Integrations.Webhooks.{Delivery, Endpoint}

  @endpoint Schemas.of(Endpoint, "Webhook")
  @delivery Schemas.of(Delivery, "WebhookDelivery")
  @types %{type: "array", items: %{type: "string", enum: Integrations.webhook_event_types()}}
  @input Schemas.input(Endpoint, "WebhookInput", ~w(url event_types), %{event_types: @types})
  @with_secret %{
    type: "object",
    properties: %{
      data: @endpoint,
      secret: %{type: "string", description: "signs deliveries; shown only here"}
    }
  }

  @signing "Deliveries are POSTed with `x-qpbx-event-id`, `x-qpbx-timestamp` and `x-qpbx-signature: v1=<hex HMAC-SHA256 of \"<timestamp>.<body>\" with the secret>`."

  def operation(:index),
    do:
      op("Webhooks", "List webhook endpoints", "admin", :tenant,
        params: Page.params(),
        response: {:list, @endpoint}
      )

  def operation(:show),
    do: op("Webhooks", "Get a webhook endpoint", "admin", :tenant, response: @endpoint)

  def operation(:create),
    do:
      op(
        "Webhooks",
        "Add an HTTPS endpoint; the secret is in this response only. " <> @signing,
        "admin",
        :tenant,
        body: @input,
        status: 201,
        response: {:raw, @with_secret}
      )

  def operation(:update),
    do:
      op("Webhooks", "Change an endpoint (URL, events, enabled)", "admin", :tenant,
        body: @input,
        response: @endpoint
      )

  def operation(:delete),
    do: op("Webhooks", "Remove an endpoint and its delivery log", "admin", :tenant, response: nil)

  def operation(:rotate),
    do:
      op(
        "Webhooks",
        "A new signing secret, in this response only; the old one stops at once",
        "admin",
        :tenant,
        response: {:raw, @with_secret}
      )

  def operation(:deliveries),
    do:
      op(
        "Webhooks",
        "An endpoint's deliveries, newest first, with every attempt",
        "admin",
        :tenant,
        params: Page.params(),
        response: {:list, @delivery}
      )

  def operation(:delivery),
    do: op("Webhooks", "Get a delivery", "admin", :tenant, response: @delivery)

  def operation(:resend),
    do:
      op("Webhooks", "Send a delivery's event again (same event id)", "admin", :tenant,
        status: 201,
        response: @delivery
      )

  def index(conn, params), do: paged(conn, Integrations.list_webhooks(scope(conn)), params)
  def show(conn, %{"id" => id}), do: with_endpoint(conn, id, &data(conn, &1))

  def create(conn, params) do
    with {:ok, e, secret} <- Integrations.create_webhook(scope(conn), params, actor(conn)),
         do: conn |> put_status(201) |> json(%{data: Schemas.render(e), secret: secret})
  end

  def update(conn, %{"id" => id} = params),
    do:
      with_endpoint(
        conn,
        id,
        &reply(
          conn,
          Integrations.update_webhook(scope(conn), &1, Map.drop(params, ["id"]), actor(conn))
        )
      )

  def delete(conn, %{"id" => id}),
    do:
      with_endpoint(
        conn,
        id,
        &reply(conn, Integrations.delete_webhook(scope(conn), &1, actor(conn)), 204)
      )

  def rotate(conn, %{"id" => id}) do
    with_endpoint(conn, id, fn e ->
      with {:ok, e, secret} <- Integrations.rotate_webhook_secret(scope(conn), e, actor(conn)),
           do: json(conn, %{data: Schemas.render(e), secret: secret})
    end)
  end

  def deliveries(conn, %{"id" => id} = params) do
    with_endpoint(conn, id, fn e ->
      with {:ok, limit, before} <- Page.keyset(params) |> bad_request() do
        rows = Integrations.list_webhook_deliveries(scope(conn), e, limit + 1, before)
        {page, next} = Page.next(rows, limit, :inserted_at)
        json(conn, %{data: Schemas.render(page), next_cursor: next})
      end
    end)
  end

  def delivery(conn, %{"id" => id}) do
    case Integrations.get_webhook_delivery(scope(conn), id) do
      nil -> {:error, :not_found}
      d -> data(conn, d)
    end
  end

  def resend(conn, %{"id" => id}) do
    case Integrations.get_webhook_delivery(scope(conn), id) do
      nil -> {:error, :not_found}
      d -> reply(conn, Integrations.resend_webhook_delivery(scope(conn), d, actor(conn)), 201)
    end
  end

  defp with_endpoint(conn, id, fun) do
    case Integrations.get_webhook(scope(conn), id) do
      nil -> {:error, :not_found}
      e -> fun.(e)
    end
  end

  defp bad_request({:error, message}) when is_binary(message),
    do: {:error, {:bad_request, message}}

  defp bad_request(ok), do: ok

  defp scope(conn), do: conn.assigns.current_scope
  defp actor(conn), do: conn.assigns.api_key
end
