defmodule QPBX.Firewall.CIDR do
  @moduledoc "Parses an IPv4/IPv6 address or prefix into canonical text (host bits cleared)."
  import Bitwise

  @doc "Returns `{:ok, canonical, :v4 | :v6, prefix_len}` or `:error`."
  def parse(text) when is_binary(text) do
    with [addr | rest] when length(rest) <= 1 <- String.split(String.trim(text), "/"),
         false <- String.contains?(addr, "%"),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(addr)),
         {fam, bits} = family(ip),
         {:ok, len} <- prefix_len(rest, bits) do
      masked = ip |> to_int(fam) |> band(mask(len, bits)) |> from_int(fam)
      shown = :inet.ntoa(masked) |> to_string()
      {:ok, if(len == bits, do: shown, else: "#{shown}/#{len}"), fam, len}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  defp family({_, _, _, _}), do: {:v4, 32}
  defp family({_, _, _, _, _, _, _, _}), do: {:v6, 128}

  defp prefix_len([], bits), do: {:ok, bits}

  defp prefix_len([len], bits) do
    case Integer.parse(len) do
      {n, ""} when n >= 0 and n <= bits -> {:ok, n}
      _ -> :error
    end
  end

  defp mask(len, bits), do: (1 <<< bits) - (1 <<< (bits - len))

  defp to_int({a, b, c, d}, :v4), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  defp to_int(t, :v6), do: t |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 16 ||| &1))

  defp from_int(n, :v4), do: {n >>> 24 &&& 255, n >>> 16 &&& 255, n >>> 8 &&& 255, n &&& 255}

  defp from_int(n, :v6),
    do: for(i <- 7..0//-1, do: n >>> (i * 16) &&& 0xFFFF) |> List.to_tuple()
end
