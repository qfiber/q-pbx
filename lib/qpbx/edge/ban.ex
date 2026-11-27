defmodule QPBX.Edge.Ban do
  @moduledoc """
  A ban Kamailio placed: a whole address (`key` = ip) or one phone (`key` = "ip|port"). Kept
  so a restarted Kamailio loads it back (`kamailio.ipban` view).
  """
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "edge_bans" do
    field :ip, :string
    field :port, :integer
    field :reason, :string
    field :expires_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
