defmodule ToolCall.TypeCompilerTest do
  use ExUnit.Case, async: true

  alias ToolCall.IR.Type
  alias ToolCall.TypeCompiler

  defp context do
    %{
      module: __MODULE__,
      env: __ENV__,
      providers: ToolCall.Typespec.builtin_providers(),
      definitions: %{}
    }
  end

  test "compiles a scalar parameter" do
    state = context() |> TypeCompiler.prepare() |> TypeCompiler.new()

    assert {%Type{kind: :integer}, false, _state} =
             TypeCompiler.compile_param(state, {:primitive, :integer})
  end

  test "compiles a recursive local type into a defs reference" do
    definitions = %{
      {:tree, 0} =>
        {[],
         {:%{}, [],
          [
            {:value, {:integer, [], []}},
            {:next, {:tree, [], []}}
          ]}}
    }

    state =
      context()
      |> Map.put(:definitions, definitions)
      |> TypeCompiler.prepare()
      |> TypeCompiler.new()

    {type, false, state} =
      TypeCompiler.compile_param(state, {:ref, {:tree, 0}, []})

    assert %Type{kind: :ref, ref: "tree"} = type
    assert map_size(TypeCompiler.defs(state)) == 1
  end

  test "colliding instantiation names take a numeric suffix" do
    insts = [
      %{name: "tree", key: {:tree, 0}, args: []},
      %{name: "tree", key: {:tree, 0}, args: []}
    ]

    assert TypeCompiler.assign_names(insts, %{}) == {%{0 => "tree", 1 => "tree_2"}, %{}}

    seeded = %{"tree" => %ToolCall.IR.Type{kind: :string}}

    assert {names, defs} = TypeCompiler.assign_names([%{name: "tree"}], seeded)
    assert names == %{0 => "tree_2"}
    assert defs == seeded
  end

  test "keeps no_return and none as never results" do
    state = context() |> TypeCompiler.prepare() |> TypeCompiler.new()

    assert {%Type{kind: :unsupported, source: :no_return}, false, _state} =
             TypeCompiler.compile_result(state, {:unsupported, :no_return})

    assert {%Type{kind: :unsupported, source: :none}, false, _state} =
             TypeCompiler.compile_result(state, {:unsupported, :none})
  end
end
