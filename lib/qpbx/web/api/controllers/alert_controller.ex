defmodule QPBX.Web.Api.AlertController do
  @moduledoc """
  Alerts (a tenant key: its tenant's; a platform key: every alert), their delivery log and
  resend, a test notification; shared recipients and alert webhooks (admin scope); mandatory
  categories (platform keys). A person's own preferences are portal-only: a key is not a person.
  """
  use QPBX.Web, :api_controller
  alias QPBX.Notify
  alias QPBX.Notify.Alerts.{Alert, Channel, Notification}
  alias QPBX.Notify.Catalogue

  @alert Schemas.of(Alert, "Alert")
  @note Schemas.of(Notification, "Notification")
  @channel Schemas.of(Channel, "AlertChannel")
  @channel_input Schemas.input(Channel, "AlertChannelInput", ~w(kind address categories), %{
                   categories: %{
                     type: "array",
                     items: %{type: "string", enum: Catalogue.categories()}
                   }
                 })
  @filters [
    query("state", "", %{type: "string", enum: ~w(open acknowledged resolved)}),
    query("category", "", %{type: "string", enum: Catalogue.categories()}),
    query("severity", "", %{type: "string", enum: Catalogue.severities()})
  ]

  def operation(:index),
    do:
      op("Alerts", "Alerts, newest first (at most 200)", "read", :any,
        params: @filters,
        response: {:list, @alert}
      )

  def operation(:show), do: op("Alerts", "Get an alert", "read", :any, response: @alert)

  def operation(:acknowledge),
    do: op("Alerts", "Acknowledge an open alert", "write", :any, response: @alert)

  def operation(:resolve),
    do:
      op(
        "Alerts",
        "Resolve an alert (everyone told of it hears it is back to normal)",
        "write",
        :any,
        response: @alert
      )

  def operation(:deliveries),
    do:
      op("Alerts", "Who was told about an alert, on which channel, and how it went", "read", :any,
        response: {:list, @note}
      )

  def operation(:resend),
    do:
      op("Alerts", "Send an email or webhook notification again", "write", :any,
        status: 201,
        response: @note
      )

  def operation(:test),
    do:
      op(
        "Alerts",
        "Send a test notification to the scope's people and channels for a category",
        "write",
        :any,
        body: %{
          type: "object",
          required: ["category"],
          properties: %{category: %{type: "string", enum: Catalogue.categories()}}
        },
        status: 201,
        response: @alert
      )

  def operation(:channels),
    do:
      op("Alerts", "Shared recipients and alert webhooks", "admin", :any,
        response: {:list, @channel}
      )

  def operation(:create_channel),
    do:
      op(
        "Alerts",
        "Add a shared recipient (email) or an alert webhook (HTTPS; the secret is in this response only)",
        "admin",
        :any,
        body: @channel_input,
        status: 201,
        response:
          {:raw,
           %{type: "object", properties: %{data: @channel, secret: %{type: ["string", "null"]}}}}
      )

  def operation(:update_channel),
    do:
      op("Alerts", "Change a shared recipient or alert webhook", "admin", :any,
        body: @channel_input,
        response: @channel
      )

  def operation(:delete_channel),
    do: op("Alerts", "Remove a shared recipient or alert webhook", "admin", :any, response: nil)

  def operation(:rules),
    do:
      op("Alerts", "Mandatory categories (people cannot switch them off)", "read", :platform,
        response:
          {:raw,
           %{type: "object", properties: %{data: %{type: "array", items: %{type: "string"}}}}}
      )

  def operation(:put_rules),
    do:
      op("Alerts", "Set the mandatory categories", "admin", :platform,
        body: %{
          type: "object",
          required: ["categories"],
          properties: %{
            categories: %{type: "array", items: %{type: "string", enum: Catalogue.categories()}}
          }
        },
        response:
          {:raw,
           %{type: "object", properties: %{data: %{type: "array", items: %{type: "string"}}}}}
      )

  def index(conn, params),
    do:
      json(conn, %{
        data:
          Schemas.render(
            Notify.list_alerts(scope(conn), Map.take(params, ~w(state category severity)), 200)
          ),
        next_cursor: nil
      })

  def show(conn, %{"id" => id}) do
    case Notify.get_alert(scope(conn), id) do
      nil -> {:error, :not_found}
      alert -> data(conn, alert)
    end
  end

  def acknowledge(conn, %{"id" => id}),
    do: reply(conn, Notify.acknowledge_alert(scope(conn), id, actor(conn)))

  def resolve(conn, %{"id" => id}),
    do: reply(conn, Notify.resolve_alert(scope(conn), id, actor(conn)))

  def deliveries(conn, %{"id" => id}) do
    case Notify.get_alert(scope(conn), id) do
      nil ->
        {:error, :not_found}

      _ ->
        json(conn, %{
          data: Schemas.render(Notify.list_alert_deliveries(scope(conn), id)),
          next_cursor: nil
        })
    end
  end

  def resend(conn, %{"id" => id}),
    do: reply(conn, Notify.resend_notification(scope(conn), id, actor(conn)), 201)

  def test(conn, %{"category" => c}) when is_binary(c) do
    if c in Catalogue.categories(),
      do: reply(conn, Notify.send_test_notification(scope(conn), c, actor(conn)), 201),
      else: {:error, :unknown_category}
  end

  def test(_conn, _), do: {:error, {:bad_request, "category is required"}}

  def channels(conn, _),
    do:
      json(conn, %{
        data: Schemas.render(Notify.list_alert_channels(scope(conn))),
        next_cursor: nil
      })

  def create_channel(conn, params) do
    with {:ok, ch, secret} <- Notify.create_alert_channel(scope(conn), params, actor(conn)),
         do: conn |> put_status(201) |> json(%{data: Schemas.render(ch), secret: secret})
  end

  def update_channel(conn, %{"id" => id} = p),
    do:
      reply(conn, Notify.update_alert_channel(scope(conn), id, Map.drop(p, ["id"]), actor(conn)))

  def delete_channel(conn, %{"id" => id}),
    do: reply(conn, Notify.delete_alert_channel(scope(conn), id, actor(conn)), 204)

  def rules(conn, _), do: json(conn, %{data: Notify.mandatory_categories()})

  def put_rules(conn, %{"categories" => cats}) when is_list(cats) do
    case cats -- Catalogue.categories() do
      [] ->
        :ok = Notify.set_mandatory_categories(scope(conn), cats, actor(conn))
        json(conn, %{data: Notify.mandatory_categories()})

      _ ->
        {:error, :unknown_category}
    end
  end

  def put_rules(_conn, _), do: {:error, {:bad_request, "categories must be a list"}}

  defp scope(conn), do: conn.assigns.current_scope
  defp actor(conn), do: conn.assigns.api_key
end
