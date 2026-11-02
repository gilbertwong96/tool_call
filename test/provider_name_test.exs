defmodule ToolCall.ProviderNameTest do
  use ExUnit.Case, async: true

  alias ToolCall.ProviderName

  test "accepts names both providers allow" do
    assert ProviderName.valid?("get_weather")
    assert ProviderName.valid?("a-b_1")
    assert Regex.match?(ProviderName.pattern(), "x")
  end

  test "rejects non-binary and malformed names" do
    refute ProviderName.valid?(:atom)
    refute ProviderName.valid?(nil)
    refute ProviderName.valid?("bad name")
    refute ProviderName.valid?(String.duplicate("a", 65))
  end
end
