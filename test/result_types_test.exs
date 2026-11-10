defmodule ToolCall.ResultTypesTest do
  use ExUnit.Case, async: true

  alias ToolCall.IR.{Tool, Type}
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

  test "a result-only recursive type is absent from the input schema" do
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

    [function] = ToolCall.emit(module, :openai)
    refute Map.has_key?(function["function"]["parameters"], "$defs")

    [spec] = ToolCall.describe(module)
    refute Map.has_key?(spec.parameters, "$defs")
  end

  test "a def shared by a parameter and the result is emitted once" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @type tree :: %{value: integer(), children: [tree()]}

        @doc "Go."
        @spec go(x :: tree()) :: tree()
        def go(x), do: x
      end
      """)

    [function] = ToolCall.emit(module, :openai)
    assert Map.keys(function["function"]["parameters"]["$defs"]) == ["tree"]
  end

  test "a result-only def never warns about what the model sees" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @type nested_node :: %{value: pid(), children: [nested_node()]}

        @doc "Go."
        @spec go(x :: integer()) :: nested_node()
        def go(_x), do: %{value: self(), children: []}
      end
      """)

    refute warnings =~ "no JSON representation"
  end

  @ok_map """
  defmodule FIXTURE do
    use ToolCall

    @doc "Go."
    @spec go(x :: integer()) :: {:ok, map()} | {:error, String.t()}
    def go(x), do: {:ok, %{x: x}}
  end
  """

  test "validation is opt-in" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: integer()
        def go(_x), do: "not an integer"
      end
      """)

    assert {:ok, "not an integer"} = ToolCall.run(module, :go, %{"x" => 1})

    assert {:error, {:invalid_result, _}} =
             ToolCall.run(module, :go, %{"x" => 1}, validate_result: true)
  end

  test "a matching raw return passes and is unwrapped" do
    module = compile!(@ok_map)
    assert {:ok, %{x: 1}} = ToolCall.run(module, :go, %{"x" => 1}, validate_result: true)
  end

  test "the payload is not what gets validated" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: {:ok, map()} | {:error, String.t()}
        def go(_x), do: {:ok, "not a map"}
      end
      """)

    assert {:ok, "not a map"} = ToolCall.run(module, :go, %{"x" => 1})

    assert {:error, {:invalid_result, _}} =
             ToolCall.run(module, :go, %{"x" => 1}, validate_result: true)
  end

  @tag capture_log: true
  test "a function that raises keeps the raised error" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: integer()
        def go(_x), do: raise(ArgumentError, "boom")
      end
      """)

    assert {:error, {:raised, "boom"}} =
             ToolCall.run(module, :go, %{"x" => 1}, validate_result: true)
  end

  test "the embedded IR drops AST sources and keeps runtime sources" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Any."
        @spec any_result(x :: integer()) :: Totally.Missing.t()
        def any_result(_x), do: :anything

        @doc "Chars."
        @spec chars(x :: integer()) :: charlist()
        def chars(_x), do: ~c"ok"

        @doc "Bad chars."
        @spec bad_chars(x :: integer()) :: charlist()
        def bad_chars(_x), do: "not a charlist"
      end
      """)

    any = Enum.find(ToolCall.tools(module), &(&1.name == "any_result"))
    assert %Type{kind: :any, source: nil} = any.result

    chars = Enum.find(ToolCall.tools(module), &(&1.name == "chars"))
    assert %Type{kind: :string, source: :charlist} = chars.result

    assert {:ok, ~c"ok"} = ToolCall.run(module, :chars, %{"x" => 1}, validate_result: true)

    assert {:error, {:invalid_result, {:expected_charlist, "not a charlist"}}} =
             ToolCall.run(module, :bad_chars, %{"x" => 1}, validate_result: true)
  end

  test "emit rejects a malformed result type" do
    bad = %Tool{
      name: "go",
      description: "Go.",
      params: [],
      defs: %{},
      result: %Type{kind: :bogus}
    }

    for target <- [:openai, :anthropic, :mcp] do
      assert_raise ArgumentError, ~r/unknown kind :bogus/, fn ->
        ToolCall.Emit.emit(bad, target)
      end
    end
  end

  test "unknown options and a non-boolean validate_result raise" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: integer()
        def go(x), do: x
      end
      """)

    assert_raise ArgumentError, ~r/unknown options/, fn ->
      ToolCall.run(module, :go, %{"x" => 1}, nope: true)
    end

    assert_raise ArgumentError, ~r/validate_result/, fn ->
      ToolCall.run(module, :go, %{"x" => 1}, validate_result: :yes)
    end
  end

  test "a tool without a result type skips validation" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: no_return()
        def go(_x), do: :anything
      end
      """)

    assert {:ok, :anything} = ToolCall.run(module, :go, %{"x" => 1}, validate_result: true)
  end

  test "nonempty_binary rejects an empty result end to end" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: nonempty_binary()
        def go(_x), do: ""
      end
      """)

    assert {:error, {:invalid_result, _}} =
             ToolCall.run(module, :go, %{"x" => 1}, validate_result: true)
  end

  test "a result-only struct does not warn about what the model sees" do
    for type <- [
          "ToolCall.TestFixtures.OpaqueBox.t()",
          "ToolCall.TestFixtures.ParamOnly.t()"
        ] do
      {_module, warnings} =
        compile_with_warnings!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Go."
          @spec go(x :: integer()) :: #{type}
          def go(_x), do: nil
        end
        """)

      refute warnings =~ "treated as {}"
      refute warnings =~ "field set is hidden"
    end
  end

  test "a struct whose t unions nil accepts nil as a result" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Find."
        @spec go(x :: integer()) :: ToolCall.TestFixtures.NullableAddress.t()
        def go(_x), do: nil
      end
      """)

    [tool] = ToolCall.tools(module)

    assert %Type{kind: :object, struct: ToolCall.TestFixtures.NullableAddress, nullable: true} =
             tool.result

    assert {:ok, nil} = ToolCall.run(module, :go, %{"x" => 1}, validate_result: true)
  end

  test "a struct type with arguments validates as a struct" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Good."
        @spec good(x :: integer()) :: ToolCall.TestFixtures.ParamOnly.t(integer())
        def good(_x), do: %ToolCall.TestFixtures.ParamOnly{a: 1}

        @doc "Bad."
        @spec bad(x :: integer()) :: ToolCall.TestFixtures.ParamOnly.t(integer())
        def bad(_x), do: 1
      end
      """)

    good = Enum.find(ToolCall.tools(module), &(&1.name == "good"))
    assert %Type{kind: :object, struct: ToolCall.TestFixtures.ParamOnly} = good.result

    assert {:ok, %ToolCall.TestFixtures.ParamOnly{a: 1}} =
             ToolCall.run(module, :good, %{"x" => 1}, validate_result: true)

    assert {:error, {:invalid_result, {:expected_struct, 1}}} =
             ToolCall.run(module, :bad, %{"x" => 1}, validate_result: true)
  end

  test "warns when the result type cannot be validated" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: term()
        def go(_x), do: :anything
      end
      """)

    assert warnings =~ "return type of go/1 has no JSON type"
    assert warnings =~ "accept any value"
    [tool] = ToolCall.tools(module)
    assert %Type{kind: :any} = tool.result
    assert {:ok, :anything} = ToolCall.run(module, :go, %{"x" => 1}, validate_result: true)
  end

  test "warns for an unsupported result type" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: fun()
        def go(_x), do: fn -> :ok end
      end
      """)

    assert warnings =~ "return type of go/1 has no JSON type"
    assert warnings =~ "accept any value"
  end

  test "warns for an unknown remote result type" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: Totally.Missing.t()
        def go(_x), do: :anything
      end
      """)

    assert warnings =~ "return type of go/1 has no JSON type"
    assert warnings =~ "accept any value"
  end

  test "warns for an opaque struct result type" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: ToolCall.TestFixtures.OpaqueBox.t()
        def go(_x), do: :anything
      end
      """)

    assert warnings =~ "is ToolCall.TestFixtures.OpaqueBox.t(), which is @opaque"
    assert warnings =~ "accept any value"
    [tool] = ToolCall.tools(module)
    assert %Type{kind: :any} = tool.result
  end

  test "does not warn for a result type that can be validated" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: map()
        def go(_x), do: %{}
      end
      """)

    refute warnings =~ "accept any value"
  end

  test "a truncated result type reports the validation blind spot once" do
    cycle =
      for i <- 0..32 do
        next = rem(i + 1, 33)
        "  @type r#{i} :: {r#{next}()}\n"
      end
      |> Enum.join()

    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

      #{cycle}
        @doc "Go."
        @spec go(x :: integer()) :: r0()
        def go(_x), do: {{}}
      end
      """)

    assert warnings =~ "expansion budget"
    assert warnings =~ "Result validation will accept any value there"
    refute warnings =~ "Narrow the type if the result must be checked"
  end

  test "Runner.run/5 rejects a non-boolean validate_result" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: integer()
        def go(x), do: x
      end
      """)

    [tool] = ToolCall.tools(module)

    assert_raise ArgumentError, ~r/validate_result/, fn ->
      ToolCall.Runner.run(module, [tool], :go, %{"x" => 1}, validate_result: :yes)
    end
  end

  test "a nullable struct result accepts nil" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Find."
        @spec go(x :: integer()) :: ToolCall.TestFixtures.Address.t() | nil
        def go(_x), do: nil
      end
      """)

    [tool] = ToolCall.tools(module)

    assert %Type{kind: :object, struct: ToolCall.TestFixtures.Address, nullable: true} =
             tool.result

    assert {:ok, nil} = ToolCall.run(module, :go, %{"x" => 1}, validate_result: true)
  end

  test "a nullable recursive struct result is a nullable ref" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Grow."
        @spec go(x :: integer()) :: ToolCall.TestFixtures.TreeNode.t() | nil
        def go(_x), do: nil
      end
      """)

    [tool] = ToolCall.tools(module)

    assert %Type{kind: :ref, nullable: true} = tool.result
    assert {:ok, nil} = ToolCall.run(module, :go, %{"x" => 1}, validate_result: true)
  end
end
