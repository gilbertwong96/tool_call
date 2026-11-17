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

  test "returns nil for no_return and none results" do
    state = context() |> TypeCompiler.prepare() |> TypeCompiler.new()

    assert {nil, false, _state} = TypeCompiler.compile_result(state, {:unsupported, :no_return})
    assert {nil, false, _state} = TypeCompiler.compile_result(state, {:unsupported, :none})
  end
end
