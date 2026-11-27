defmodule QPBX.Firewall.Store do
  @moduledoc "Database access for firewall entries, with audit entries in the same transaction."
  import Ecto.Query
  alias QPBX.Core
  alias QPBX.Core.{PlatformAdmin, User}
  alias QPBX.Firewall.Entry
  alias QPBX.Repo

  def active_entries(now \\ DateTime.utc_now()) do
    Repo.all(from e in Entry, where: is_nil(e.expires_at) or e.expires_at > ^now)
  end

  def list(opts) do
    query = from e in Entry, order_by: [e.level, e.kind, e.scope, e.cidr]

    query =
      case Keyword.fetch(opts, :tenant_id) do
        {:ok, id} -> from e in query, where: e.tenant_id == ^id
        :error -> query
      end

    case Keyword.fetch(opts, :level) do
      {:ok, level} -> Repo.all(from e in query, where: e.level == ^level)
      :error -> Repo.all(query)
    end
  end

  def get!(id), do: Repo.get!(Entry, id)

  def create(attrs, actor) do
    {author_type, author_id} = author(actor)
    cs = Entry.changeset(%Entry{author_type: author_type, author_id: author_id}, attrs)

    Repo.transaction(fn ->
      with {:ok, entry} <- Repo.insert(cs),
           {:ok, _} <- Core.audit(actor, "firewall_entry.create", entry, cs.changes) do
        entry
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def delete(%Entry{} = entry, actor) do
    Repo.transaction(fn ->
      # Lock all management entries so two concurrent deletes cannot both pass the check.
      others =
        Repo.all(
          from e in Entry,
            where: e.level == "platform" and e.kind == "allow" and e.scope in ["ssh", "all"],
            where: e.id != ^entry.id and is_nil(e.expires_at),
            lock: "FOR UPDATE"
        )

      if Entry.management?(entry) and others == [] do
        Repo.rollback(:last_management_entry)
      else
        delete_audited(entry, actor)
      end
    end)
  end

  defp delete_audited(entry, actor) do
    changes = Map.take(entry, [:kind, :scope, :cidr, :level])

    with {:ok, deleted} <- Repo.delete(entry),
         {:ok, _} <- Core.audit(actor, "firewall_entry.delete", deleted, changes) do
      deleted
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp author(%PlatformAdmin{id: id}), do: {"platform_admin", id}
  defp author(%User{id: id}), do: {"user", id}
  defp author({:system, name}), do: {"system:" <> name, nil}
end
