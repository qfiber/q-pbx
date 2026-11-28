defmodule QPBX.Core.ApiKeys do
  @moduledoc """
  API keys (tenant scope: the tenant's keys; platform scope: the platform's keys) and the
  check behind every API request. A key is `qpbx_` and 43 random characters; only its
  SHA-256 is stored, so it is shown once. Revoking deletes the row: the next request with it
  fails. `QPBX.Core.Idempotency` keeps POST replays per key.
  """
  import Ecto.Query
  alias QPBX.Core.{ApiKey, Audit, Scope}
  alias QPBX.Repo

  # Write "last used" at most this often; every request is still checked.
  @touch_every 60
  @default_platform_rate 600

  def list(%Scope{} = scope) do
    Scope.run(scope, fn -> Repo.all(from k in own(scope), order_by: [desc: k.inserted_at]) end)
  end

  def change(attrs \\ %{}), do: ApiKey.changeset(%ApiKey{}, attrs)

  @doc "Creates a key: `{:ok, key, token}`; the token is not kept anywhere."
  def create(%Scope{} = scope, attrs, actor) do
    raw = :crypto.strong_rand_bytes(32)
    token = "qpbx_" <> Base.url_encode64(raw, padding: false)

    cs =
      %ApiKey{
        tenant_id: scope.tenant_id,
        prefix: String.slice(token, 0, 12),
        token_hash: hash(token)
      }
      |> ApiKey.changeset(attrs)

    Scope.run(scope, fn ->
      with {:ok, key} <- Repo.insert(cs) do
        Repo.insert!(
          Audit.entry(actor, "api_key.create", key, Map.take(key, [:name, :scopes, :expires_at]))
        )

        {:ok, key}
      end
    end)
    |> case do
      {:ok, key} -> {:ok, key, token}
      error -> error
    end
  end

  @doc "Revokes (deletes) one of the scope's keys."
  def revoke(%Scope{} = scope, id, actor) do
    Scope.run(scope, fn ->
      case Repo.one(from k in own(scope), where: k.id == ^id) do
        nil ->
          {:error, :not_found}

        key ->
          Repo.delete!(key)
          Repo.insert!(Audit.entry(actor, "api_key.revoke", key, %{name: key.name}))
          {:ok, key}
      end
    end)
  end

  @doc """
  The key behind a request's bearer token, with its tenant and plan: `{:ok, key}`, or
  `{:error, :invalid | :expired}`. Records use at most once a minute.
  """
  def authenticate("qpbx_" <> _ = token) do
    case Repo.one(from k in ApiKey, where: k.token_hash == ^hash(token), preload: [tenant: :plan]) do
      nil -> {:error, :invalid}
      key -> if ApiKey.expired?(key), do: {:error, :expired}, else: {:ok, touch(key)}
    end
  end

  def authenticate(_), do: {:error, :invalid}

  @doc "Requests per minute the key may make: the tenant's plan limit (nil: unlimited)."
  def rate_limit(%ApiKey{tenant: nil}),
    do: Application.get_env(:qpbx, :platform_api_rate_limit, @default_platform_rate)

  def rate_limit(%ApiKey{tenant: tenant}),
    do: QPBX.Core.effective_limits(tenant)[:api_rate_limit_per_minute]

  defp touch(%ApiKey{last_used_at: last} = key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if is_nil(last) or DateTime.diff(now, last) >= @touch_every do
      Repo.update_all(from(k in ApiKey, where: k.id == ^key.id), set: [last_used_at: now])
      %{key | last_used_at: now}
    else
      key
    end
  end

  defp own(%Scope{kind: :tenant, tenant_id: tid}),
    do: from(k in ApiKey, where: k.tenant_id == ^tid)

  defp own(%Scope{kind: :platform}), do: from(k in ApiKey, where: is_nil(k.tenant_id))

  defp hash(token), do: :crypto.hash(:sha256, token)
end
