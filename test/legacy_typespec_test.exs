defmodule ToolCall.LegacyTypespecTest do
  use ExUnit.Case, async: true

  alias ToolCall.LegacyTypespec
  alias ToolCall.TestFixtures.Address

  test "reads the legacy typespec chunk and converts a type back to quoted AST" do
    assert {:ok, entries} = LegacyTypespec.fetch_types(Address)
    assert {:type, {:t, body, []}} = Enum.find(entries, &match?({:type, {:t, _, []}}, &1))

    assert {:"::", _, [{:t, _, []}, _type_ast]} =
             LegacyTypespec.type_to_quoted({:t, body, []})
  end
end
