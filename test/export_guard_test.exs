defmodule ToolCall.ExportGuardTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.ToolCall.Export

  test "refuses to encode without json:format/1" do
    assert_raise Mix.Error, ~r/OTP 27.1/, fn -> Export.encode(%{}, false) end
  end

  test "detects the formatter on the running OTP" do
    expected = Code.ensure_loaded?(:json) and function_exported?(:json, :format, 1)
    assert Export.json_format?() == expected
  end
end
