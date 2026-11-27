defmodule QPBX.Edge.Settings do
  @moduledoc """
  SIP edge protection settings (one row). Kamailio reads them at run time from the
  `kamailio.settings` view, reloaded when they change; no restart.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :boolean, autogenerate: false}
  schema "edge_settings" do
    field :flood_requests, :integer
    field :register_per_minute, :integer
    field :invite_per_minute, :integer
    field :auth_failures_port, :integer
    field :auth_failures_ip, :integer
    field :ban_seconds, :integer
    field :scanner_agents, :string
    timestamps(type: :utc_datetime)
  end

  @numbers [
    flood_requests: 5..100_000,
    register_per_minute: 5..10_000,
    invite_per_minute: 5..10_000,
    auth_failures_port: 3..10_000,
    auth_failures_ip: 3..100_000,
    # nftables element timeouts go up to 30 days.
    ban_seconds: 60..2_592_000
  ]

  def ranges, do: @numbers

  def changeset(settings, attrs) do
    cs =
      settings
      |> cast(attrs, [:scanner_agents | Keyword.keys(@numbers)])
      |> validate_required([:scanner_agents | Keyword.keys(@numbers)])

    @numbers
    |> Enum.reduce(cs, fn {f, a..b//_}, cs ->
      validate_number(cs, f, greater_than_or_equal_to: a, less_than_or_equal_to: b)
    end)
    |> validate_change(:scanner_agents, &validate_agents/2)
  end

  # Matched by Kamailio as a regular expression against the User-Agent: only plain names joined
  # by |, each at least 3 characters (an empty one would match every phone and ban everyone).
  defp validate_agents(:scanner_agents, value) do
    parts = String.split(value, "|")

    if String.length(value) <= 1000 and
         Enum.all?(parts, &Regex.match?(~r/\A[A-Za-z0-9 ._-]{3,64}\z/, &1)),
       do: [],
       else: [
         scanner_agents:
           "names of at least 3 letters, digits, space, dot, dash or underscore, separated by |"
       ]
  end
end
