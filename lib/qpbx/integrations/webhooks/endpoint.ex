defmodule QPBX.Integrations.Webhooks.Endpoint do
  @moduledoc "A tenant's webhook endpoint: an HTTPS URL, the event types it wants, its signing secret."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "webhook_endpoints" do
    field :tenant_id, :binary_id
    field :url, :string
    field :description, :string
    field :event_types, {:array, :string}, default: []
    field :secret, QPBX.Core.Encrypted.Binary, redact: true
    field :enabled, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [:url, :description, :event_types, :enabled])
    |> update_change(:event_types, &Enum.reject(&1, fn t -> t in ["", nil] end))
    |> update_change(:url, &String.trim/1)
    |> validate_required([:url])
    |> validate_length(:url, max: 2000)
    |> validate_length(:description, max: 200)
    |> then(
      &if(get_field(&1, :event_types) == [],
        do: add_error(&1, :event_types, "pick at least one event"),
        else: &1
      )
    )
    |> validate_subset(:event_types, QPBX.Integrations.Webhooks.Event.types())
    |> validate_format(:url, ~r{\Ahttps://}i, message: "must start with https://")
  end

  @doc "On saving: the URL's host must be a public address now (checked again on every delivery)."
  def check_destination(%Ecto.Changeset{valid?: true, changes: %{url: url}} = cs) do
    case QPBX.Integrations.OutboundHTTP.check_destination(url) do
      :ok -> cs
      {:error, {:blocked_address, _}} -> add_error(cs, :url, "points to an internal address")
      {:error, :nxdomain} -> add_error(cs, :url, "has a host name that does not resolve")
      {:error, :https_required} -> add_error(cs, :url, "must start with https://")
      {:error, _} -> add_error(cs, :url, "is not a valid URL")
    end
  end

  def check_destination(cs), do: cs
end
