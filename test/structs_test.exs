defmodule ToolCall.StructsTest do
  use ExUnit.Case, async: true

  alias ToolCall.Structs

  alias ToolCall.TestFixtures.{
    Address,
    NotAStruct,
    OpaqueBox,
    Partial,
    PathNode,
    PrivateField,
    TreeNode
  }

  test "struct?/1 recognises compiled structs" do
    assert Structs.struct?(Address)
    refute Structs.struct?(NotAStruct)
  end

  test "enforced_keys/1 recovers @enforce_keys" do
    assert {:ok, [:city]} = Structs.enforced_keys(Address)
    assert {:ok, []} = Structs.enforced_keys(Partial)
  end

  test "fields/1 returns field types with the module's local types expanded" do
    assert {:ok, fields, []} = Structs.fields(Address)
    assert {String, :t, []} = unwrap_remote(fields.city)
    assert {String, :t, []} = unwrap_remote(fields.street)
  end

  test "fields/1 and enforced_keys/1 reject a non-struct" do
    assert :error = Structs.fields(NotAStruct)
    assert :error = Structs.enforced_keys(NotAStruct)
  end

  test "fields/1 returns the module's own cyclic types as instantiations" do
    assert {:ok, fields, [inst]} = Structs.fields(PathNode)
    assert inst.key == {:path, 0}
    assert match?({:|, _, [_, nil]}, fields.tail)
  end

  test "fields/1 reports opaque types" do
    assert :opaque = Structs.fields(OpaqueBox)
  end

  test "fields/1 lists defstruct fields missing from @type t" do
    assert {:ok, fields, []} = Structs.fields(Partial)
    assert Map.keys(fields) |> Enum.sort() == [:a, :b, :c]
    assert match?({:any, _, []}, fields.b)
  end

  test "fields/1 turns a self-referential t/0 into a struct marker" do
    assert {:ok, fields, []} = Structs.fields(TreeNode)
    assert [marker] = fields.children
    assert match?({:%, _, [TreeNode, {:%{}, _, []}]}, marker)
  end

  test "fields/1 leaves @typep references as local calls" do
    assert {:ok, fields, []} = Structs.fields(PrivateField)
    assert match?({:hidden, _, []}, fields.hidden)
  end

  defp unwrap_remote({{:., _, [module, function]}, _, args}) when is_atom(module),
    do: {module, function, args}

  defp unwrap_remote({:|, _, [value, nil]}), do: unwrap_remote(value)
  defp unwrap_remote(other), do: other
end
