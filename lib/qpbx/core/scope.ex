defmodule QPBX.Core.Scope do
  @moduledoc """
  Who a request acts for. Tenant-facing functions in `QPBX.Core` take a scope and, for a
  tenant scope, run their queries inside `QPBX.Core.with_tenant/2`, so row-level security
  hides every other tenant's rows even if a query forgets its tenant filter.
  """
  alias QPBX.Core.{PlatformAdmin, User}

  @enforce_keys [:kind]
  defstruct [:kind, :tenant_id, :account]

  @type t :: %__MODULE__{kind: :platform | :tenant, tenant_id: binary() | nil, account: struct()}

  def for_account(%PlatformAdmin{} = admin), do: %__MODULE__{kind: :platform, account: admin}

  def for_account(%User{tenant_id: id} = user),
    do: %__MODULE__{kind: :tenant, tenant_id: id, account: user}

  @doc "Runs `fun` with this scope's database restrictions; returns its result."
  def run(%__MODULE__{kind: :platform}, fun), do: fun.()

  def run(%__MODULE__{kind: :tenant, tenant_id: id}, fun) when is_binary(id) do
    {:ok, result} = QPBX.Core.with_tenant(id, fun)
    result
  end
end
