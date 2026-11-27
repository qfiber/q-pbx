defmodule QPBX.Firewall do
  @moduledoc """
  Public API of the firewall area: allow and block lists applied to nftables through `qpbx-fwd`.
  See `lib/qpbx/firewall/README.md`.
  """
  use Boundary, deps: [QPBX.Repo, QPBX.Core, QPBX.Events], exports: [Entry, Sync]

  alias QPBX.Events
  alias QPBX.Events.FirewallChanged
  alias QPBX.Firewall.{CIDR, Entry, Sets, Store, Sync}

  defdelegate list_entries(opts \\ []), to: Store, as: :list
  defdelegate get_entry!(id), to: Store, as: :get!

  def change_entry(attrs \\ %{}), do: Entry.changeset(%Entry{}, attrs)

  @doc "Adds an entry (audited) and tells every node to apply it."
  def create_entry(attrs, actor), do: Store.create(attrs, actor) |> notify("create")

  @doc "Removes an entry (audited). Refuses `{:error, :last_management_entry}`."
  def delete_entry(%Entry{} = entry, actor), do: Store.delete(entry, actor) |> notify("delete")

  @doc """
  Whether `ip` is on the platform allowlist for `scope` ("ssh", "sip" or "https"), directly or
  through an "all" entry. Allowed IPs are never blocked or challenged by login limits.
  """
  def allowlisted?(ip, scope) when is_tuple(ip) do
    Store.active_entries()
    |> Enum.any?(fn e ->
      e.level == "platform" and e.kind == "allow" and e.scope in [scope, "all"] and
        CIDR.contains?(e.cidr, ip)
    end)
  end

  @doc """
  Blocks SIP from one address for `seconds` (automatic bans from the edge). Never blocks an
  address on the platform SIP allowlist or a tenant office IP: returns `{:ok, :allowlisted}` or
  `{:ok, :office_ip}` instead. Extends an existing ban. Broadcasts `FirewallChanged`.
  """
  def ban(ip, reason, seconds, actor) when is_binary(ip) and seconds > 0 do
    with {:ok, tuple} <- :inet.parse_strict_address(String.to_charlist(ip)),
         {:ok, canonical, _fam, _len} <- CIDR.parse(ip) do
      cond do
        allowlisted?(tuple, "sip") ->
          {:ok, :allowlisted}

        office_ip?(tuple) ->
          {:ok, :office_ip}

        true ->
          canonical
          |> Store.ban(reason, until(seconds), actor)
          |> notify("ban")
      end
    else
      _ -> {:error, :invalid_address}
    end
  end

  defp until(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)

  @doc "Whether `ip` is inside a tenant's office IP entry."
  def office_ip?(ip) when is_tuple(ip) do
    Store.active_entries()
    |> Enum.any?(&(&1.level == "tenant" and &1.kind == "allow" and CIDR.contains?(&1.cidr, ip)))
  end

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
