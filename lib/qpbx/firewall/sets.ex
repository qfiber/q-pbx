defmodule QPBX.Firewall.Sets do
  @moduledoc """
  Maps entries to the named nftables sets that `qpbx-fwd` manages. One set per kind, scope
  and family, for example `allow_ssh_v4` or `block_sip_v6`. Scope `all` fills every scope's set.

  The base ruleset (Ansible `nftables` role) gives these sets their meaning:
  SSH is accepted only from `allow_ssh_*`; for SIP and HTTPS, `allow_*` is accepted before
  `block_*` is dropped, so the allowlist always wins.
  """
  alias QPBX.Firewall.Entry

  @scopes ~w(ssh sip https)

  @doc "Every managed set name with its nftables family, as `qpbx-fwd -sets` expects them."
  def all do
    for kind <- Entry.kinds(), scope <- @scopes, fam <- ~w(v4 v6) do
      {"#{kind}_#{scope}_#{fam}", if(fam == "v4", do: :ipv4, else: :ipv6)}
    end
  end

  @doc "`qpbx-fwd -sets` flag value."
  def flag, do: Enum.map_join(all(), ",", fn {name, fam} -> "#{name}:#{fam}" end)

  @doc "Desired contents of every set (sorted, unique) for the given active entries."
  def desired(entries) do
    empty = Map.new(all(), fn {name, _} -> {name, []} end)

    entries
    |> Enum.flat_map(fn e ->
      for s <- scopes_of(e.scope), do: {"#{e.kind}_#{s}_#{e.family}", e.cidr}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {set, cidrs} -> {set, cidrs |> Enum.uniq() |> Enum.sort()} end)
    |> then(&Map.merge(empty, &1))
  end

  defp scopes_of("all"), do: @scopes
  defp scopes_of(scope), do: [scope]
end
