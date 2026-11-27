defmodule QPBX.Core.Changes do
  @moduledoc false
  # Audited writes for telephony configuration, and the ConfigChanged announcement callers
  # make after their transaction commits.
  alias QPBX.Core.Audit
  alias QPBX.Events.ConfigChanged
  alias QPBX.Repo

  def insert(cs, actor, action) do
    with {:ok, rec} <- Repo.insert(cs) do
      Repo.insert!(Audit.entry(actor, action, rec, cs))
      {:ok, rec}
    end
  end

  def update(cs, actor, action) do
    with {:ok, rec} <- Repo.update(cs) do
      Repo.insert!(Audit.entry(actor, action, rec, cs))
      {:ok, rec}
    end
  end

  def delete(rec, actor, action, summary \\ %{}) do
    with {:ok, rec} <- Repo.delete(rec) do
      Repo.insert!(Audit.entry(actor, action, rec, summary))
      {:ok, rec}
    end
  end

  @doc "Passes the result through; on success announces `kind` for the tenant (nil: platform)."
  def announce({:ok, _} = ok, tenant_id, kind) do
    QPBX.Events.publish(%ConfigChanged{tenant_id: tenant_id, kind: kind, at: DateTime.utc_now()})
    ok
  end

  def announce(other, _tenant_id, _kind), do: other
end
