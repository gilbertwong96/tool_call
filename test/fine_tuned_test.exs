defmodule ToolCall.FineTunedTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  defp module do
    compile!("""
    defmodule FIXTURE do
      use ToolCall

      @doc "Go."
      @spec go(
              a :: char(),
              b :: Date.t(),
              c :: pos_integer(),
              d :: nonempty_binary(),
              e :: nonempty_list(integer()),
              f :: integer() | nil
            ) :: :ok
      def go(_a, _b, _c, _d, _e, _f), do: :ok
    end
    """)
  end

  test "fine-tuned strict keeps the strict shape and drops unsupported constraints" do
    declaration = module() |> ToolCall.emit(:openai, strict: :fine_tuned) |> hd()
    parameters = declaration["function"]["parameters"]
    properties = parameters["properties"]

    assert declaration["strict"] == true
    assert parameters["additionalProperties"] == false
    assert Enum.sort(parameters["required"]) == ["a", "b", "c", "d", "e", "f"]

    refute Map.has_key?(properties["a"], "pattern")
    refute Map.has_key?(properties["b"], "format")
    refute Map.has_key?(properties["c"], "minimum")
    refute Map.has_key?(properties["d"], "pattern")
    refute Map.has_key?(properties["e"], "minItems")
    assert properties["f"]["type"] == ["integer", "null"]
  end

  test "normal strict keeps the constraints" do
    declaration = module() |> ToolCall.emit(:openai, strict: true) |> hd()
    properties = declaration["function"]["parameters"]["properties"]

    assert properties["a"]["pattern"]
    assert properties["b"]["format"] == "date"
    assert properties["c"]["minimum"] == 1
    assert properties["d"]["pattern"]
    assert properties["e"]["minItems"] == 1
  end

  test "describe accepts the fine-tuned mode" do
    [spec] = ToolCall.describe(module(), strict: :fine_tuned)
    refute Map.has_key?(spec.parameters["properties"]["c"], "minimum")
  end

  test "an unknown strict mode raises" do
    assert_raise ArgumentError, ~r/fine_tuned/, fn ->
      ToolCall.emit(module(), :openai, strict: :bogus)
    end
  end
end
