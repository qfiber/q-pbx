defmodule QPBX.Web.NumberInput do
  @moduledoc """
  Form fields where people type phone numbers the local way (02-123-4567): each value becomes
  E.164 with the scope's number rule before Core sees it. A value that is not a number (or a
  short extension number) is passed on as typed, so Core's validation reports it.
  """
  alias QPBX.Core

  def normalize(params, scope, fields) do
    Enum.reduce(fields, params, fn field, acc ->
      case Map.get(acc, field) do
        list when is_list(list) -> Map.put(acc, field, Enum.map(list, &one(&1, scope)))
        value when is_binary(value) -> Map.put(acc, field, one(value, scope))
        _ -> acc
      end
    end)
  end

  @doc "Comma- or space-separated text into a list (follow-me numbers, prefixes)."
  def split(nil), do: []

  def split(text),
    do:
      text
      |> String.split([",", "\n", ";"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp one(value, scope) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      Regex.match?(~r/\A\d{1,6}\z/, value) -> value
      true -> with(:error <- Core.to_e164(scope, value), do: value) |> ok_value()
    end
  end

  defp ok_value({:ok, e164}), do: e164
  defp ok_value(value), do: value
end
