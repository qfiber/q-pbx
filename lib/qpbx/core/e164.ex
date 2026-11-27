defmodule QPBX.Core.E164 do
  @moduledoc "Changeset checks for phone numbers stored in E.164 (+ and up to 15 digits)."
  import Ecto.Changeset

  @e164 ~r/\A\+[1-9]\d{1,14}\z/
  # Where a number or an internal extension is allowed (forwarding targets, follow-me).
  @target ~r/\A(\+[1-9]\d{1,14}|\d{1,10})\z/

  def validate(cs, field),
    do: validate_format(cs, field, @e164, message: "must be E.164, e.g. +97221234567")

  def validate_target(cs, field),
    do: validate_format(cs, field, @target, message: "an extension or an E.164 number")

  def validate_targets(cs, field) do
    validate_change(cs, field, fn _, list ->
      if Enum.all?(list, &Regex.match?(@target, &1)),
        do: [],
        else: [{field, "each must be an extension or an E.164 number"}]
    end)
  end

  @doc "An E.164 prefix: + and 1 to 15 digits."
  def validate_prefixes(cs, field) do
    validate_change(cs, field, fn _, list ->
      if Enum.all?(List.wrap(list), &Regex.match?(~r/\A\+\d{1,15}\z/, &1)),
        do: [],
        else: [{field, "each must look like +972 or +9725"}]
    end)
  end
end
