defmodule QPBX.Core.Numbers do
  @moduledoc """
  Number handling with a tenant's `NumberRule`: what people dial or type into E.164, E.164
  back into the national way of writing it, the destination class of a number, and the number
  a route sends to its carrier. Pure functions; callers load the rule, classes and routes.
  """
  alias QPBX.Core.{NumberRule, OutboundRoute}

  @valid ~r/\A\+[1-9]\d{6,14}\z/

  @doc """
  `{:ok, e164}` or `:error`. Accepts +E.164, an international prefix (00, 012…), the national
  prefix (0), or, when the rule has an area code, a local number without it. Spaces, dashes,
  dots and brackets are ignored.

  shortcut: no country-specific short forms (Israeli 1-800 or *star numbers); add a per-rule
  "dial as is" prefix list when a tenant needs them.
  """
  def to_e164(input, %NumberRule{} = rule) when is_binary(input) do
    s = String.replace(input, ~r/[\s\-.()\/]/, "")

    candidate = expand(s, rule)

    if candidate && Regex.match?(@valid, candidate), do: {:ok, candidate}, else: :error
  end

  @doc "How a number is shown to the tenant: national form at home, international prefix abroad."
  def display("+" <> digits = e164, %NumberRule{} = rule) do
    shown =
      if String.starts_with?(digits, rule.country_code),
        do: (rule.national_prefix || "") <> drop(digits, rule.country_code),
        else: hd(rule.international_prefixes) <> digits

    if shown == "", do: e164, else: shown
  end

  def display(other, _rule), do: other

  @doc """
  The destination class: the longest matching prefix of `classes` (`[{prefix, class}]`),
  else "local" at home and "international" abroad.
  """
  def classify("+" <> digits = e164, %NumberRule{} = rule, classes) do
    case classes
         |> Enum.filter(fn {prefix, _} -> String.starts_with?(e164, prefix) end)
         |> Enum.max_by(&String.length(elem(&1, 0)), fn -> nil end) do
      {_, class} -> class
      nil -> if String.starts_with?(digits, rule.country_code), do: "local", else: "international"
    end
  end

  @doc "The first enabled route (by position) with a matching prefix; a route without prefixes matches all."
  def select_route(e164, routes) do
    routes
    |> Enum.filter(& &1.enabled)
    |> Enum.sort_by(& &1.position)
    |> Enum.find(fn r ->
      r.prefixes == [] or Enum.any?(r.prefixes, &String.starts_with?(e164, &1))
    end)
  end

  @doc "The number sent to the carrier: E.164 as is, or the digits after `strip_digits` with `add_prefix` in front."
  def carrier_number(%OutboundRoute{strip_digits: 0, add_prefix: ""}, e164), do: e164

  def carrier_number(%OutboundRoute{strip_digits: n, add_prefix: add}, "+" <> digits),
    do: (add || "") <> String.slice(digits, n..-1//1)

  defp expand("+" <> _ = s, _rule), do: s

  defp expand(s, rule) do
    intl = Enum.find(by_length(rule.international_prefixes), &String.starts_with?(s, &1))

    national =
      rule.national_prefix not in [nil, ""] and String.starts_with?(s, rule.national_prefix)

    cond do
      intl ->
        "+" <> drop(s, intl)

      national ->
        "+" <> rule.country_code <> drop(s, rule.national_prefix)

      rule.area_code && Regex.match?(~r/\A[1-9]\d{4,}\z/, s) ->
        "+" <> rule.country_code <> rule.area_code <> s

      true ->
        nil
    end
  end

  defp by_length(prefixes), do: Enum.sort_by(prefixes, &(-String.length(&1)))
  defp drop(s, prefix), do: binary_part(s, byte_size(prefix), byte_size(s) - byte_size(prefix))
end
