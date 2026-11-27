defmodule QPBX.Core.TrunkAddress do
  @moduledoc """
  One signalling address of a trunk (IP or host name). Calls from any address are accepted;
  outbound calls use the lowest priority first, weight shares load within one priority.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "trunk_addresses" do
    field :tenant_id, :binary_id
    field :host, :string
    field :port, :integer, default: 5060
    field :transport, :string, default: "udp"
    field :priority, :integer, default: 1
    field :weight, :integer, default: 1
    belongs_to :trunk, QPBX.Core.Trunk
    timestamps(type: :utc_datetime)
  end

  # shortcut: no DNS SRV lookups yet (a host name resolves by A/AAAA); add SRV in 2-3 if a carrier needs it.
  def changeset(address, attrs, tenant_id) do
    address
    |> cast(attrs, [:host, :port, :transport, :priority, :weight])
    |> put_change(:tenant_id, tenant_id)
    |> validate_required([:host])
    |> validate_change(:host, &validate_host/2)
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> validate_inclusion(:transport, ~w(udp tcp tls))
    |> validate_number(:priority, greater_than: 0, less_than: 100)
    |> validate_number(:weight, greater_than: 0, less_than: 100)
  end

  defp validate_host(:host, host) do
    ip? = match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(host)))

    name? =
      Regex.match?(
        ~r/\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/i,
        host
      )

    if ip? or name?, do: [], else: [host: "an IP address or a host name"]
  end
end
