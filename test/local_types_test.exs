defmodule ToolCall.LocalTypesProxy do
  defmacro __before_compile__(env) do
    {ast, false} = ToolCall.LocalTypes.expand({:t, [], []}, env.module)

    quote do
      def __expanded_type__, do: unquote(Macro.escape(ast))
    end
  end
end

defmodule ToolCall.LocalTypesFixture do
  @type t :: integer()
  @before_compile ToolCall.LocalTypesProxy
end

defmodule ToolCall.LocalTypesTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  test "expand/2 accepts a module while it is still open" do
    assert {:integer, _meta, []} = ToolCall.LocalTypesFixture.__expanded_type__()
  end

  test "var_name/1 leaves a non-variable parameter alone" do
    assert ToolCall.LocalTypes.var_name({:t, [], nil}) == :t
    assert ToolCall.LocalTypes.var_name(:literal) == :literal
  end

  test "resolves a @type alias declared in the same module" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @type city :: String.t()

        @doc "Alias."
        @spec go(c :: city()) :: :ok
        def go(_c), do: :ok
      end
      """)

    assert param_schema(module, "go", "c") == %{"type" => "string"}
  end

  test "resolves @typep and @opaque aliases" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @typep hidden :: integer()
        @opaque secret :: String.t()

        @doc "Private and opaque."
        @spec go(a :: hidden(), b :: secret()) :: :ok
        def go(_a, _b), do: :ok
      end
      """)

    assert param_schema(module, "go", "a") == %{"type" => "integer"}
    assert param_schema(module, "go", "b") == %{"type" => "string"}
  end

  test "substitutes type parameters" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @type pair(a, b) :: {a, b}

        @doc "Parameterised."
        @spec go(p :: pair(integer(), String.t()), l :: list(pair(:x, :y))) :: :ok
        def go(_p, _l), do: :ok
      end
      """)

    assert %{"prefixItems" => [%{"type" => "integer"}, %{"type" => "string"}]} =
             param_schema(module, "go", "p")

    assert %{
             "items" => %{
               "prefixItems" => [
                 %{"type" => "string", "enum" => ["x"]},
                 %{"type" => "string", "enum" => ["y"]}
               ]
             }
           } = param_schema(module, "go", "l")
  end

  test "resolves current-module references inside alias bodies" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall
        alias __MODULE__, as: Self

        @type city :: String.t()
        @type location :: __MODULE__.city()
        @type self_location :: Self.city()

        @spec go(a :: location(), b :: self_location()) :: :ok
        def go(_a, _b), do: :ok
      end
      """)

    assert param_schema(module, "go", "a") == %{"type" => "string"}
    assert param_schema(module, "go", "b") == %{"type" => "string"}
  end

  test "inlines a local type used as a remote type's argument" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @type value :: integer()

        @doc "Keyword values."
        @spec go(opts :: Keyword.t(value())) :: keyword(integer())
        def go(opts), do: opts
      end
      """)

    assert param_schema(module, "go", "opts")["additionalProperties"] == %{"type" => "integer"}
    assert ToolCall.run(module, "go", %{"opts" => %{"n" => 1.0}}) == {:ok, [n: 1]}
  end

  test "expands nested aliases" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @type id :: pos_integer()
        @type user :: %{id: id(), name: String.t()}

        @doc "Nested."
        @spec go(u :: user()) :: :ok
        def go(_u), do: :ok
      end
      """)

    assert %{
             "properties" => %{
               "id" => %{"type" => "integer", "minimum" => 1},
               "name" => %{"type" => "string"}
             },
             "required" => ["id", "name"]
           } = param_schema(module, "go", "u")
  end

  @tag timeout: 20_000
  test "stops expanding past the inlining budget instead of exploding" do
    depth = 24

    types =
      for i <- 0..depth do
        if i == depth do
          "  @type t#{i} :: integer()\n"
        else
          "  @type t#{i} :: {t#{i + 1}(), t#{i + 1}()}\n"
        end
      end

    source = """
    defmodule FIXTURE do
      use ToolCall

    #{Enum.join(types)}
      @doc "Deep."
      @spec go(x :: t0()) :: :ok
      def go(_x), do: :ok
    end
    """

    {_us, {module, warnings}} = :timer.tc(fn -> compile_with_warnings!(source) end)

    assert warnings =~ "expansion"
    schema = param_schema(module, "go", "x")
    assert %{"type" => "array", "prefixItems" => [_, _]} = schema
    assert nodes(schema) < 5_000
  end

  defp nodes(term) when is_map(term),
    do: 1 + Enum.sum(for {key, value} <- term, do: nodes(key) + nodes(value))

  defp nodes(term) when is_list(term), do: 1 + Enum.sum(Enum.map(term, &nodes/1))
  defp nodes(_term), do: 1

  test "stops at recursive definitions instead of expanding forever" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @type tree :: {:node, tree(), tree()}

        @doc "Recursive."
        @spec go(t :: tree() | nil) :: :ok
        def go(_t), do: :ok
      end
      """)

    assert %{
             "type" => ["array", "null"],
             "prefixItems" => [%{"type" => "string", "enum" => ["node"]}, %{}, %{}],
             "minItems" => 3
           } = param_schema(module, "go", "t")
  end
end
