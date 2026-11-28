defmodule QPBX.Core.Audit do
  @moduledoc "Writes audit entries inside the same transaction as the change."
  alias Ecto.Multi
  alias QPBX.Core.{ApiKey, AuditLog, PlatformAdmin, User}

  # Never written to the audit log, even as changed values.
  @secret_fields ~w(hashed_password password totp_secret ha1 push_token token_hash)a

  @type actor :: %PlatformAdmin{} | %User{} | %ApiKey{} | {:system, String.t()}

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
    tenant_id = tenant_of(target) || tenant_of(actor)

    %AuditLog{
      tenant_id: tenant_id,
      actor_type: actor_type,
      actor_id: actor_id,
      actor_label: actor_label(actor),
      action: action,
      target_type: target && target.__struct__ |> Module.split() |> List.last(),
      target_id: target && Map.get(target, :id),
      target_label: target_label(target),
      tenant_label: tenant_label(target, tenant_id),
      changes: clean(changes)
    }
  end

  defp actor_label(%{name: name, email: email}) when is_binary(name),
    do: label("#{name} (#{email})")

  defp actor_label(%ApiKey{name: name}), do: label(name)
  defp actor_label(_), do: nil

  # A record's own name: an extension's number and name, else the first naming field it has.
  @doc false
  def target_label(nil), do: nil

  def target_label(%{number: n, name: name}) when is_binary(n) and is_binary(name),
    do: label("#{n} #{name}")

  def target_label(target) do
    ~w(email name number cidr prefix url label username)a
    |> Enum.find_value(&(Map.get(target, &1) |> nonblank()))
    |> label()
  end

  defp tenant_label(%QPBX.Core.Tenant{name: name}, _), do: label(name)
  defp tenant_label(_, nil), do: nil

  defp tenant_label(_, tenant_id) do
    case QPBX.Repo.get(QPBX.Core.Tenant, tenant_id) do
      %{name: name} -> label(name)
      nil -> nil
    end
  end

  defp nonblank(v) when is_binary(v) and v != "", do: v
  defp nonblank(_), do: nil

  defp label(nil), do: nil
  defp label(text), do: String.slice(text, 0, 200)

  defp actor_ref(%PlatformAdmin{id: id}), do: {"platform_admin", id}
  defp actor_ref(%User{id: id}), do: {"user", id}
  defp actor_ref(%ApiKey{id: id}), do: {"api_key", id}
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
