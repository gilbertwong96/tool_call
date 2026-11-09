defmodule ToolCall.ResultTypesTest do
  use ExUnit.Case, async: true

  alias ToolCall.IR.{Param, Tool, Type}
  import ToolCall.TestModule

  defp tool(source) do
    module = compile!(source)
    Enum.find(ToolCall.tools(module), &(&1.name == "go"))
  end

  test "a native return type lands on the tool" do
    assert %Tool{result: %Type{kind: :integer, minimum: 1}} =
             tool("""
             defmodule FIXTURE do
               use ToolCall

               @doc "Go."
               @spec go(x :: integer()) :: pos_integer()
               def go(x), do: x
             end
             """)
  end

  test "an ok/error tuple union keeps both branches" do
    assert %Tool{result: %Type{kind: :union, variants: variants}} =
             tool("""
             defmodule FIXTURE do
               use ToolCall

               @doc "Go."
               @spec go(x :: integer()) :: {:ok, map()} | {:error, String.t()}
               def go(x), do: {:ok, %{x: x}}
             end
             """)

    assert Enum.map(variants, & &1.kind) |> Enum.sort() == [:tuple, :tuple]
  end

  test "a struct return type is resolved like a parameter" do
    assert %Tool{result: %Type{kind: :object, struct: ToolCall.TestFixtures.Address}} =
             tool("""
             defmodule FIXTURE do
               use ToolCall

               @doc "Go."
               @spec go(x :: integer()) :: ToolCall.TestFixtures.Address.t()
               def go(_x), do: %ToolCall.TestFixtures.Address{city: "Oslo"}
             end
             """)
  end

  test "a result-only recursive type shares defs" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @type tree :: %{value: integer(), children: [tree()]}

        @doc "Go."
        @spec go(x :: integer()) :: tree()
        def go(_x), do: %{value: 1, children: []}
      end
      """)

    [tool] = ToolCall.tools(module)
    assert %Type{kind: :ref, ref: "tree"} = tool.result
    assert Map.has_key?(tool.defs, "tree")
  end

  test "no_return() leaves the result empty" do
    assert %Tool{result: nil} =
             tool("""
             defmodule FIXTURE do
               use ToolCall

               @doc "Go."
               @spec go(x :: integer()) :: no_return()
               def go(x), do: raise(ArgumentError, inspect(x))
             end
             """)
  end

  test "validate_tool!/1 rejects a dangling result ref" do
    assert_raise ArgumentError, ~r/unknown \$defs entry/, fn ->
      ToolCall.Typespec.validate_tool!(%Tool{
        name: "go",
        description: "Go.",
        result: %Type{kind: :ref, ref: "missing"}
      })
    end
  end

  test "validate_tool!/1 rejects a malformed result type" do
    assert_raise ArgumentError, fn ->
      ToolCall.Typespec.validate_tool!(%Tool{
        name: "go",
        description: "Go.",
        result: %Type{kind: :struct, struct: Date}
      })
    end
  end
end
