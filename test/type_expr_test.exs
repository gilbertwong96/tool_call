defmodule ToolCall.TypeExprTest do
  use ExUnit.Case, async: true

  alias ToolCall.TypeExpr
  alias ToolCall.TypeExpr.Typespec

  defp from_ast(ast), do: Typespec.from_ast(ast)

  test "translates primitives and literals" do
    assert from_ast({:integer, [], []}) == {:primitive, :integer}
    assert from_ast({:boolean, [], []}) == {:primitive, :boolean}
    assert from_ast({:binary, [], []}) == {:string, %{source: :binary}}
    assert from_ast(true) == {:literal, true}
    assert from_ast(nil) == {:literal, nil}
    assert from_ast(:red) == {:literal, :red}
  end

  test "keeps integer refinements as annotations" do
    assert from_ast({:pos_integer, [], []}) ==
             {:annotated, {:primitive, :integer}, %{minimum: 1}}

    assert from_ast({:.., [], [1, 10]}) == {:integer_range, 1, 10}
  end

  test "translates unions, lists, tuples, and maps" do
    assert from_ast({:|, [], [{:integer, [], []}, {:binary, [], []}]}) ==
             {:union, [{:primitive, :integer}, {:string, %{source: :binary}}]}

    assert from_ast([{:integer, [], []}]) == {:list, {:primitive, :integer}}

    assert from_ast([{:integer, [], []}, {:..., [], []}]) ==
             {:nonempty_list, {:primitive, :integer}}

    assert from_ast({:{}, [], [{:integer, [], []}, {:binary, [], []}]}) ==
             {:tuple, [{:primitive, :integer}, {:string, %{source: :binary}}]}

    ast =
      {:%{}, [],
       [
         {:name, {:binary, [], []}},
         {{:optional, [], [:age]}, {:integer, [], []}}
       ]}

    assert from_ast(ast) ==
             {:map,
              [
                {:name, {:string, %{source: :binary}}, true},
                {:age, {:primitive, :integer}, false}
              ], nil}
  end

  test "keeps remote, builtin, and recursive refs unresolved" do
    assert from_ast({{:., [], [String, :t]}, [], []}) == {:remote, String, :t, []}
    assert from_ast({{:., [], [Date, :t]}, [], []}) == {:remote, Date, :t, []}
    assert from_ast({:keyword, [], []}) == {:builtin, :keyword, []}
    assert from_ast({:tuple, [], []}) == {:tuple, nil}

    ref = {{:., [], [:tool_call_ref, :ref]}, [], ["tree"]}
    assert from_ast(ref) == {:ref, "tree"}
  end

  test "a non-JSON literal degrades instead of crashing" do
    assert %ToolCall.IR.Type{kind: :unsupported} =
             ToolCall.TypeExpr.Compiler.to_type({:literal, {1, 2}}, [])
  end

  test "a malformed expression degrades to unsupported" do
    assert %ToolCall.IR.Type{kind: :unsupported, source: {:invalid_type_expr, :nope}} =
             ToolCall.TypeExpr.Compiler.to_type(:nope, [])

    for malformed <- [
          {:map, :not_a_list, nil},
          {:tuple, :not_a_list},
          {:union, :not_a_list},
          {:remote, String, :t, :not_a_list},
          {:string, :not_a_map},
          {:enum, :not_a_list},
          {:annotated, {:primitive, :integer}, :not_a_map}
        ] do
      assert %ToolCall.IR.Type{kind: :unsupported} =
               ToolCall.TypeExpr.Compiler.to_type(malformed, [])
    end
  end

  test "keeps unsupported types explicit" do
    assert from_ast({:fun, [], []}) == {:unsupported, :fun}
    assert from_ast({:pid, [], []}) == {:unsupported, :pid}
    assert from_ast({:term, [], []}) == :any
    assert TypeExpr.none() == :none
  end
end
