defmodule QPBX.Firewall do
  @moduledoc """
  Public API of the firewall area: allow and block lists applied to nftables through `qpbx-fwd`.
  See `lib/qpbx/firewall/CLAUDE.md`.
  """
  use Boundary, deps: [QPBX.Repo, QPBX.Core, QPBX.Events], exports: [Entry, Sync]

  alias QPBX.Events
  alias QPBX.Events.FirewallChanged
  alias QPBX.Firewall.{Entry, Sets, Store, Sync}

  defdelegate list_entries(opts \\ []), to: Store, as: :list
  defdelegate get_entry!(id), to: Store, as: :get!

  def change_entry(attrs \\ %{}), do: Entry.changeset(%Entry{}, attrs)

  @doc "Adds an entry (audited) and tells every node to apply it."
  def create_entry(attrs, actor), do: Store.create(attrs, actor) |> notify("create")

  @doc "Removes an entry (audited). Refuses `{:error, :last_management_entry}`."
  def delete_entry(%Entry{} = entry, actor), do: Store.delete(entry, actor) |> notify("delete")

  @doc "Reconciles this node now; returns `%{at, errors, skipped}`."
  defdelegate sync_now(), to: Sync, as: :run_now
  defdelegate sync_status(), to: Sync, as: :status

  @doc "The `-sets` flag value for `qpbx-fwd` (used by the Ansible role)."
  defdelegate helper_sets_flag(), to: Sets, as: :flag

  defp notify({:ok, _} = ok, reason) do
    Events.publish(%FirewallChanged{at: DateTime.utc_now(), reason: reason})
    ok
  end

  defp notify(error, _reason), do: error
end
