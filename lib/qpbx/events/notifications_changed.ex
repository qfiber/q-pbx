defmodule QPBX.Events.NotificationsChanged do
  @moduledoc """
  A person's portal notifications changed (a new one, or read): their open pages update the
  bell. `account_type` is `user` or `platform_admin`. Version 1.
  """
  @enforce_keys [:account_type, :account_id, :at]
  defstruct version: 1, account_type: nil, account_id: nil, at: nil

  def topic, do: "notifications"
end
