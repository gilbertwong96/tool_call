defmodule ToolCall.TypeCompilerTest do
  use ExUnit.Case, async: true

  alias ToolCall.IR.Type
  alias ToolCall.{LocalTypes, TypeCompiler}

  defp context do
    %{
      module: __MODULE__,
      env: __ENV__,
      providers: ToolCall.Typespec.builtin_providers(),
      definitions: %{},
      cyclic: MapSet.new()
    }
  end

  test "compiles a scalar parameter and keeps its source AST" do
    state = TypeCompiler.new(context())

    assert {%Type{kind: :integer}, {:integer, _, []}, false, _state} =
             TypeCompiler.compile_param(state, {:integer, [], []}, %{})
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
      TypeCompiler.new(%{
        context()
        | definitions: definitions,
          cyclic: LocalTypes.cyclic_keys(definitions)
      })

    {type, _source, false, state} =
      TypeCompiler.compile_param(state, {:tree, [], []}, %{})

    assert %Type{kind: :ref} = type
    assert map_size(TypeCompiler.defs(state)) == 1
  end

  test "returns nil for no_return and none results" do
    state = TypeCompiler.new(context())

    assert {nil, false, _state} =
             TypeCompiler.compile_result(state, {:no_return, [], []}, %{})

    assert {nil, false, _state} = TypeCompiler.compile_result(state, {:none, [], []}, %{})
  end
end
