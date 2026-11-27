defmodule QPBX.Core.NumbersTest do
  use ExUnit.Case, async: true
  alias QPBX.Core.{NumberRule, Numbers, OutboundRoute}

  @il NumberRule.israel_default()
  @il_jlm %{@il | area_code: "2"}

  test "Israeli dialing to E.164" do
    for {dialed, e164} <- [
          {"02-123-4567", "+97221234567"},
          {"050-123-4567", "+972501234567"},
          {"(03) 123.4567", "+97231234567"},
          {"+972 2 123 4567", "+97221234567"},
          {"00 44 20 7946 0000", "+442079460000"},
          {"014 1 212 555 0100", "+12125550100"},
          {"012-49-30-1234567", "+49301234567"}
        ] do
      assert Numbers.to_e164(dialed, @il) == {:ok, e164}, dialed
    end
  end

  test "short local numbers use the area code only when the rule has one" do
    assert Numbers.to_e164("1234567", @il) == :error
    assert Numbers.to_e164("1234567", @il_jlm) == {:ok, "+97221234567"}
  end

  test "rejects what is not a number" do
    for bad <- ["", "abc", "0", "+0123456789", "+1234", "*2000", "00"],
        do: assert(Numbers.to_e164(bad, @il) == :error, bad)
  end

  test "another country's rule" do
    us = %NumberRule{country_code: "1", national_prefix: "1", international_prefixes: ["011"]}
    assert Numbers.to_e164("1 212 555 0100", us) == {:ok, "+12125550100"}
    assert Numbers.to_e164("011 972 2 123 4567", us) == {:ok, "+97221234567"}
  end

  test "display: national at home, international abroad" do
    assert Numbers.display("+97221234567", @il) == "021234567"
    assert Numbers.display("+442079460000", @il) == "00442079460000"
  end

  test "classify: longest prefix wins, default by country" do
    classes = [{"+9725", "mobile"}, {"+97259", "premium"}, {"+44", "international"}]
    assert Numbers.classify("+972501234567", @il, classes) == "mobile"
    assert Numbers.classify("+972591234567", @il, classes) == "premium"
    assert Numbers.classify("+97221234567", @il, classes) == "local"
    assert Numbers.classify("+12125550100", @il, classes) == "international"
  end

  test "route selection by position and prefix; carrier number rewrite" do
    any = %OutboundRoute{
      name: "any",
      prefixes: [],
      position: 9,
      enabled: true,
      strip_digits: 0,
      add_prefix: ""
    }

    il = %OutboundRoute{
      name: "il",
      prefixes: ["+972"],
      position: 1,
      enabled: true,
      strip_digits: 3,
      add_prefix: "0"
    }

    off = %OutboundRoute{name: "off", prefixes: ["+972"], position: 0, enabled: false}
    assert Numbers.select_route("+97221234567", [any, il, off]).name == "il"
    assert Numbers.select_route("+442079460000", [any, il, off]).name == "any"
    assert Numbers.select_route("+44", [il]) == nil
    assert Numbers.carrier_number(il, "+97221234567") == "021234567"
    assert Numbers.carrier_number(any, "+442079460000") == "+442079460000"
  end
end
