defmodule QPBX.Core.Audit do
  @moduledoc "Writes audit entries inside the same transaction as the change."
  alias Ecto.Multi
  alias QPBX.Core.{AuditLog, PlatformAdmin, User}

  # Never written to the audit log, even as changed values.
  @secret_fields ~w(hashed_password password totp_secret ha1 push_token)a

  @type actor :: %PlatformAdmin{} | %User{} | {:system, String.t()}

  @doc """
  Appends an audit insert to `multi`. `target_step` names the multi step whose result is the
  changed record; `changes` is a changeset or a map of what changed.
  """
  def add(%Multi{} = multi, actor, action, target_step, changes) do
    Multi.insert(multi, {:audit, target_step}, fn results ->
      target = Map.fetch!(results, target_step)
      entry(actor, action, target, changes)
    end)
  end

  @doc "Runs `multi` in a transaction and returns the result of `step`."
  def commit(%Multi{} = multi, step) do
    case QPBX.Repo.transaction(multi) do
      {:ok, results} -> {:ok, Map.fetch!(results, step)}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  def entry(actor, action, target, changes) do
    {actor_type, actor_id} = actor_ref(actor)

    %AuditLog{
      tenant_id: tenant_of(target) || tenant_of(actor),
      actor_type: actor_type,
      actor_id: actor_id,
      action: action,
      target_type: target && target.__struct__ |> Module.split() |> List.last(),
      target_id: target && Map.get(target, :id),
      changes: clean(changes)
    }
  end

  defp actor_ref(%PlatformAdmin{id: id}), do: {"platform_admin", id}
  defp actor_ref(%User{id: id}), do: {"user", id}
  defp actor_ref({:system, name}), do: {"system:" <> name, nil}

  defp tenant_of(%QPBX.Core.Tenant{id: id}), do: id
  defp tenant_of(%{tenant_id: id}), do: id
  defp tenant_of(_), do: nil

  defp clean(%Ecto.Changeset{changes: changes}), do: clean(changes)

  defp clean(changes) when is_map(changes) do
    changes
    |> Map.drop(@secret_fields)
    |> Map.new(fn {k, v} -> {k, json_safe(v)} end)
  end

  defp json_safe(%Ecto.Changeset{} = cs), do: clean(cs)
  defp json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_safe(v) when is_map(v) and not is_struct(v), do: v
  defp json_safe(v) when is_list(v), do: Enum.map(v, &json_safe/1)

  defp json_safe(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v) or is_atom(v),
    do: v

  defp json_safe(v), do: inspect(v)
end
