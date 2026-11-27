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

  @doc """
  An automatic SIP block of one address until `until`: a platform block entry with reason
  "auto: ...". An existing block for the address is extended (never shortened, and a
  permanent one is left alone). Returns `{:ok, entry}`.
  """
  def ban(cidr, reason, until, actor) do
    Repo.transaction(fn ->
      existing =
        Repo.one(
          from e in Entry,
            where:
              e.level == "platform" and e.kind == "block" and e.scope == "sip" and e.cidr == ^cidr,
            lock: "FOR UPDATE"
        )

      case ban_into(existing, cidr, "auto: " <> reason, until, actor) do
        {:ok, entry} -> entry
        {:error, e} -> Repo.rollback(e)
      end
    end)
  end

  defp ban_into(nil, cidr, reason, until, actor),
    do:
      create(
        %{
          level: "platform",
          kind: "block",
          scope: "sip",
          cidr: cidr,
          reason: reason,
          expires_at: until
        },
        actor
      )

  # A permanent block stays as it is.
  defp ban_into(%Entry{expires_at: nil} = entry, _cidr, _reason, _until, _actor), do: {:ok, entry}

  defp ban_into(%Entry{} = entry, _cidr, reason, until, actor) do
    if DateTime.compare(entry.expires_at, until) == :lt do
      entry = entry |> Ecto.Changeset.change(expires_at: until, reason: reason) |> Repo.update!()
      {:ok, _} = Core.audit(actor, "firewall_entry.extend", entry, %{expires_at: until})
      {:ok, entry}
    else
      {:ok, entry}
    end
  end

  @doc "Removes automatic bans that expired more than a week ago (the audit log keeps them)."
  def purge_expired_bans(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -7, :day)
    Repo.delete_all(from e in Entry, where: like(e.reason, "auto: %") and e.expires_at < ^cutoff)
  end

  defp author(%PlatformAdmin{id: id}), do: {"platform_admin", id}
  defp author(%User{id: id}), do: {"user", id}
  defp author({:system, name}), do: {"system:" <> name, nil}
end
