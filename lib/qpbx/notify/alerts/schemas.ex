defmodule QPBX.Notify.Alerts.Alert do
  @moduledoc "One problem (or personal notice), with its state and how often it repeated."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "alerts" do
    field :tenant_id, :binary_id
    field :key, :string
    field :kind, :string
    field :category, :string
    field :severity, :string
    field :title, :string
    field :message, :string
    field :data, :map, default: %{}
    field :user_id, :binary_id
    field :state, :string, default: "open"
    field :count, :integer, default: 1
    field :repeats, :integer, default: 0
    field :notified_at, :utc_datetime_usec
    field :acknowledged_at, :utc_datetime
    field :acknowledged_by, :string
    field :resolved_at, :utc_datetime
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule QPBX.Notify.Alerts.Notification do
  @moduledoc """
  What one recipient was told about one alert, on one channel (portal, email, webhook), and
  how the delivery went. Portal ones are the bell's list (`read_at`).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notifications" do
    field :tenant_id, :binary_id
    field :event, :string
    field :channel, :string
    field :account_type, :string
    field :account_id, :binary_id
    field :alert_channel_id, :binary_id
    field :address, :string
    field :status, :string, default: "pending"
    field :reason, :string
    field :attempts, {:array, :map}, default: []
    field :read_at, :utc_datetime
    field :ack_token_hash, :binary, redact: true
    belongs_to :alert, QPBX.Notify.Alerts.Alert
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule QPBX.Notify.Alerts.Preference do
  @moduledoc """
  A person's choices: channels (`portal`, `email`) per category, and quiet hours (local hours,
  start to end; critical alerts ignore them).
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias QPBX.Notify.Catalogue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notification_preferences" do
    field :tenant_id, :binary_id
    field :account_type, :string
    field :account_id, :binary_id
    field :channels, :map, default: %{}
    field :quiet_start, :integer
    field :quiet_end, :integer
    field :timezone, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(pref, attrs) do
    pref
    |> cast(attrs, [:channels, :quiet_start, :quiet_end, :timezone])
    |> validate_change(:timezone, fn :timezone, tz ->
      if match?({:ok, _}, DateTime.now(tz)), do: [], else: [timezone: "is not a known time zone"]
    end)
    |> validate_number(:quiet_start, greater_than_or_equal_to: 0, less_than: 24)
    |> validate_number(:quiet_end, greater_than_or_equal_to: 0, less_than: 24)
    |> validate_change(:channels, fn :channels, channels ->
      ok =
        is_map(channels) and
          Enum.all?(channels, fn {cat, list} ->
            cat in Catalogue.categories() and is_list(list) and
              list -- ~w(portal email) == []
          end)

      if ok, do: [], else: [channels: "has an unknown category or channel"]
    end)
  end
end

defmodule QPBX.Notify.Alerts.Channel do
  @moduledoc """
  A shared recipient (`kind` email: an address such as it@) or an alert webhook (`kind`
  webhook: an HTTPS URL, signed with its secret; `format` generic, or alertmanager for
  Alertmanager-style receivers), of a tenant or of the platform (no tenant).
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias QPBX.Notify.Catalogue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "alert_channels" do
    field :tenant_id, :binary_id
    field :kind, :string
    field :address, :string
    field :categories, {:array, :string}, default: []
    field :min_severity, :string, default: "info"
    field :format, :string, default: "generic"
    field :secret, QPBX.Core.Encrypted.Binary, redact: true
    field :enabled, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  def changeset(ch, attrs) do
    ch
    |> cast(attrs, [:kind, :address, :categories, :min_severity, :format, :enabled])
    |> update_change(:categories, &Enum.reject(&1, fn c -> c in ["", nil] end))
    |> update_change(:address, &String.trim/1)
    |> validate_required([:kind, :address])
    |> validate_inclusion(:kind, ~w(email webhook))
    |> validate_inclusion(:min_severity, Catalogue.severities())
    |> validate_inclusion(:format, ~w(generic alertmanager))
    |> validate_length(:address, max: 2000)
    |> then(
      &if(get_field(&1, :categories) == [],
        do: add_error(&1, :categories, "pick at least one category"),
        else: &1
      )
    )
    |> validate_subset(:categories, Catalogue.categories())
    |> validate_address()
  end

  defp validate_address(cs) do
    case get_field(cs, :kind) do
      "email" ->
        validate_format(cs, :address, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
          message: "must be a valid email"
        )

      "webhook" ->
        validate_format(cs, :address, ~r{\Ahttps://}i, message: "must start with https://")

      _ ->
        cs
    end
  end
end

defmodule QPBX.Notify.Alerts.Rule do
  @moduledoc "A category platform admins made mandatory: people cannot switch it off."
  use Ecto.Schema

  @primary_key {:category, :string, autogenerate: false}
  schema "alert_rules" do
    field :mandatory, :boolean, default: false
    timestamps(type: :utc_datetime)
  end
end
