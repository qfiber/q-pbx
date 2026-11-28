defmodule QPBX.Integrations.Webhooks.Delivery do
  @moduledoc """
  One event sent to one endpoint, and every attempt at it (the delivery log). `status`:
  pending (an attempt is due), delivered (a 2xx answer), dead (no 2xx within 24 hours).
  An attempt: `at`, `status` (HTTP status or nil), `error`, `duration_ms`, `response` (the
  answer's first 2 KB).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "webhook_deliveries" do
    field :tenant_id, :binary_id
    field :endpoint_id, :binary_id
    field :event_id, :binary_id
    field :event_type, :string
    field :payload, :string
    field :status, :string, default: "pending"
    field :attempts, {:array, :map}, default: []
    field :delivered_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
