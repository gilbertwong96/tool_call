defmodule ToolCall.BuiltinProvidersTest do
  use ExUnit.Case, async: true

  alias ToolCall.IR.Type
  import ToolCall.TestModule

  defp tool(source) do
    module = compile!(source)
    Enum.find(ToolCall.tools(module), &(&1.name == "go"))
  end

  defp param_schema(source) do
    module = compile!(source)
    [tool] = ToolCall.emit(module, :openai)
    get_in(tool, ["function", "parameters", "properties", "x"])
  end

  defp module(source), do: compile!(source)

  @mapset """
  defmodule FIXTURE do
    use ToolCall
    @doc "Go."
    @spec go(x :: MapSet.t()) :: map()
    def go(x), do: x
  end
  """

  @mapset_integer """
  defmodule FIXTURE do
    use ToolCall
    @doc "Go."
    @spec go(x :: MapSet.t(integer())) :: map()
    def go(x), do: x
  end
  """

  test "MapSet.t() is an array, not its internal map field" do
    assert %Type{kind: :array, items: %Type{kind: :any}} = hd(tool(@mapset).params).type
    assert param_schema(@mapset) == %{"type" => "array", "items" => %{}}
  end

  test "MapSet.t(integer()) is an array of that element type" do
    assert %Type{kind: :array, items: %Type{kind: :integer}} =
             hd(tool(@mapset_integer).params).type
  end

  test "MapSet dispatch returns a set and dedupes" do
    module = module(@mapset_integer)

    assert {:ok, %MapSet{} = set} = ToolCall.run(module, :go, %{"x" => [1, 1, 2]})
    assert set |> MapSet.to_list() |> Enum.sort() == [1, 2]
  end

  test "MapSet rejects a non-list and a wrong element" do
    module = module(@mapset_integer)

    assert {:error, {:invalid_argument, {"x", {:expected_array, "nope"}}}} =
             ToolCall.run(module, :go, %{"x" => "nope"})

    assert {:error, {:invalid_argument, {"x", {0, {:expected_integer, "a"}}}}} =
             ToolCall.run(module, :go, %{"x" => ["a"]})
  end

  test "MapSet.t(struct) embeds the resolved struct" do
    assert %Type{kind: :array, items: %Type{kind: :object, struct: ToolCall.TestFixtures.Address}} =
             hd(
               tool("""
               defmodule FIXTURE do
                 use ToolCall
                 @doc "Go."
                 @spec go(x :: MapSet.t(ToolCall.TestFixtures.Address.t())) :: map()
                 def go(x), do: x
               end
               """).params
             ).type
  end

  test "Regex.t() is a string and dispatch compiles it" do
    source = """
    defmodule FIXTURE do
      use ToolCall
      @doc "Go."
      @spec go(x :: Regex.t()) :: map()
      def go(x), do: Regex.match?(x, "abc")
    end
    """

    assert param_schema(source) == %{"type" => "string"}
    assert {:ok, true} = ToolCall.run(module(source), :go, %{"x" => "^a"})
  end

  test "provider coercion rejects a value of the wrong wire shape" do
    assert {:error, {:expected_array, :x}} = ToolCall.Providers.MapSet.coerce(:x)
    assert {:error, {:expected_string, :x}} = ToolCall.Providers.Regex.coerce(:x)
  end

  test "an invalid regex source is an argument error the model can retry" do
    source = """
    defmodule FIXTURE do
      use ToolCall
      @doc "Go."
      @spec go(x :: Regex.t()) :: map()
      def go(x), do: x
    end
    """

    assert {:error, {:invalid_argument, {"x", {:invalid_regex, _message, _position}}}} =
             ToolCall.run(module(source), :go, %{"x" => "("})
  end
end
