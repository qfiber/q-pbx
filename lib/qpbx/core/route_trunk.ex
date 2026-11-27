defmodule QPBX.Core.RouteTrunk do
  @moduledoc "A trunk on an outbound route, at its place in the failover order."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "route_trunks" do
    field :tenant_id, :binary_id
    field :route_id, :binary_id
    field :trunk_id, :binary_id
    field :position, :integer, default: 0
  end
end
