defmodule QPBX.Integrations.Address do
  @moduledoc """
  Which addresses an outbound request may reach: public unicast only. Refused: this host,
  private and shared networks, link-local (cloud metadata lives there), multicast, reserved
  and documentation ranges, and every IPv6 form that carries an IPv4 address (mapped,
  compatible, NAT64, 6to4, Teredo), so no form of an inside address gets through.
  """
  import Bitwise

  @v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @v6 [
    # :: and ::1, and IPv4-compatible ::a.b.c.d
    {{0, 0, 0, 0, 0, 0, 0, 0}, 96},
    # IPv4-mapped ::ffff:a.b.c.d
    {{0, 0, 0, 0, 0, 0xFFFF, 0, 0}, 96},
    # NAT64 (well-known and local-use prefixes)
    {{0x64, 0xFF9B, 0, 0, 0, 0, 0, 0}, 96},
    {{0x64, 0xFF9B, 1, 0, 0, 0, 0, 0}, 48},
    # discard-only
    {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
    # Teredo, documentation, 6to4
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    # unique local, link-local, old site-local, multicast
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFEC0, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc "True when `ip` (a tuple) is a public address, or inside one of the `allow` CIDRs."
  def allowed?(ip, allow \\ []), do: public?(ip) or Enum.any?(allow, &in_cidr?(ip, &1))

  def public?({_, _, _, _} = ip), do: not Enum.any?(@v4, &in_range?(ip, &1))
  def public?({_, _, _, _, _, _, _, _} = ip), do: not Enum.any?(@v6, &in_range?(ip, &1))

  @doc ~s[`"10.0.0.0/8"` or `"2001:db8::1"` (one address) contains `ip`; malformed: false.]
  def in_cidr?(ip, cidr) when is_binary(cidr) do
    {addr, len} =
      case String.split(cidr, "/", parts: 2) do
        [a, l] -> {a, Integer.parse(l)}
        [a] -> {a, :all}
      end

    with {:ok, net} <- :inet.parse_strict_address(String.to_charlist(addr)),
         len when is_integer(len) <- prefix(len, net) do
      in_range?(ip, {net, len})
    else
      _ -> false
    end
  end

  defp prefix(:all, net), do: bits(net)
  defp prefix({n, ""}, net) when n >= 0, do: if(n <= bits(net), do: n)
  defp prefix(_, _), do: nil

  defp in_range?(ip, {net, len}) when tuple_size(ip) == tuple_size(net) do
    size = bits(ip)
    mask = (1 <<< size) - (1 <<< (size - len))
    band(int(ip), mask) == band(int(net), mask)
  end

  defp in_range?(_, _), do: false

  defp bits(ip) when tuple_size(ip) == 4, do: 32
  defp bits(_), do: 128

  defp int({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp int(ip) when tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &((&2 <<< 16) + &1))
end
