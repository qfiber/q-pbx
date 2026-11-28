defmodule QPBX.Core.Idempotency do
  @moduledoc """
  Idempotency keys for API POSTs. The first request with a key claims it; a repeat with the
  same request gets the stored response, a repeat with a different request is refused, and a
  repeat while the first still runs is told so. Records live 24 hours; a claim whose request
  never finished (a crash) is given up after a minute.
  """
  import Ecto.Query
  alias QPBX.Core.ApiKey
  alias QPBX.Repo

  defmodule Record do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id
    schema "api_idempotency" do
      field :tenant_id, :binary_id
      field :api_key_id, :binary_id
      field :key, :string
      field :fingerprint, :binary
      field :status, :integer
      field :body, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end
  end

  @keep 24 * 3600
  @abandoned 60

  @doc """
  Claims `key` for this request: `:claimed`, `{:replay, status, body}`, `:in_progress` or
  `:mismatch` (the key was used for a different request).
  """
  def claim(%ApiKey{} = api_key, key, fingerprint) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.delete_all(
      from r in Record,
        where:
          r.api_key_id == ^api_key.id and
            (r.inserted_at < ^DateTime.add(now, -@keep) or
               (is_nil(r.status) and r.inserted_at < ^DateTime.add(now, -@abandoned)))
    )

    row = %{
      id: Ecto.UUID.generate(),
      tenant_id: api_key.tenant_id,
      api_key_id: api_key.id,
      key: key,
      fingerprint: fingerprint,
      inserted_at: now
    }

    case Repo.insert_all(Record, [row],
           on_conflict: :nothing,
           conflict_target: [:api_key_id, :key]
         ) do
      {1, _} -> :claimed
      {0, _} -> existing(api_key, key, fingerprint)
    end
  end

  defp existing(api_key, key, fingerprint) do
    case Repo.get_by(Record, api_key_id: api_key.id, key: key) do
      # Finished and removed in between: treat as new.
      nil -> claim(api_key, key, fingerprint)
      %{fingerprint: f} when f != fingerprint -> :mismatch
      %{status: nil} -> :in_progress
      %{status: status, body: body} -> {:replay, status, body}
    end
  end

  @doc "Stores the response of a claimed request; a server error frees the key for a retry."
  def finish(%ApiKey{id: id}, key, status, _body) when status >= 500 do
    Repo.delete_all(from r in Record, where: r.api_key_id == ^id and r.key == ^key)
    :ok
  end

  def finish(%ApiKey{id: id}, key, status, body) do
    Repo.update_all(from(r in Record, where: r.api_key_id == ^id and r.key == ^key),
      set: [status: status, body: body]
    )

    :ok
  end
end
