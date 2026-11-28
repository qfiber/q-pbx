defmodule QPBX.Core.Scope do
  @moduledoc """
  Who a request acts for. Tenant-facing functions in `QPBX.Core` take a scope and, for a
  tenant scope, run their queries inside `QPBX.Core.with_tenant/2`, so row-level security
  hides every other tenant's rows even if a query forgets its tenant filter.
  """
  alias QPBX.Core.{ApiKey, PlatformAdmin, User}

  @enforce_keys [:kind]
  defstruct [:kind, :tenant_id, :account]

  @type t :: %__MODULE__{kind: :platform | :tenant, tenant_id: binary() | nil, account: struct()}

  def for_account(%PlatformAdmin{} = admin), do: %__MODULE__{kind: :platform, account: admin}

  def for_account(%User{tenant_id: id} = user),
    do: %__MODULE__{kind: :tenant, tenant_id: id, account: user}

  # An API key acts in its tenant, or for the platform when it has none.
  def for_account(%ApiKey{tenant_id: nil} = key), do: %__MODULE__{kind: :platform, account: key}

  def for_account(%ApiKey{tenant_id: id} = key),
    do: %__MODULE__{kind: :tenant, tenant_id: id, account: key}

  @doc """
  Runs `fun` in a transaction with this scope's database restrictions and returns its result.
  If `fun` returns `{:error, _}`, the transaction is rolled back and that error returned.
  """
  def run(%__MODULE__{kind: :platform}, fun) do
    QPBX.Repo.transaction(fn ->
      case fun.() do
        {:error, _} = error -> QPBX.Repo.rollback(error)
        result -> result
      end
    end)
    |> unwrap()
  end

  def run(%__MODULE__{kind: :tenant, tenant_id: id}, fun) when is_binary(id),
    do: id |> QPBX.Core.with_tenant(fun) |> unwrap()

  defp unwrap(result) do
    case result do
      {:ok, result} -> result
      # The function's own {:error, _}, after the rollback.
      {:error, {:error, _} = error} -> error
    end
  end
end
