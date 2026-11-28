defmodule QPBX.Events.LoginAlert do
  @moduledoc """
  Something about a portal login: `kind` `new_ip` (a login from an address this account has
  not used), `failed_2fa` (a wrong code after the right password), `account_failures` (failed
  logins on one account, every 5th), `ip_blocked` (an address blocked after failed logins).
  `account_type` (user, platform_admin) and `account_id` when an account is involved.
  Version 1.
  """
  @enforce_keys [:kind, :at]
  defstruct version: 1,
            kind: nil,
            account_type: nil,
            account_id: nil,
            tenant_id: nil,
            ip: nil,
            detail: nil,
            at: nil

  def topic, do: "logins"
end
