defmodule ToolCall.ProjectionTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  @plain """
  defmodule FIXTURE do
    use ToolCall

    @doc "Exercise the projection matrix."
    @spec go(
            union :: integer() | String.t(),
            count :: pos_integer(),
            date :: Date.t(),
            tags :: [String.t(), ...],
            pair :: {integer(), String.t()},
            meta :: map(),
            note :: %{optional(:text) => term()}
          ) :: :ok
    def go(_union, _count, _date, _tags, _pair, _meta, _note), do: :ok
  end
  """

  @recursive """
  defmodule FIXTURE do
    use ToolCall

    @type tree :: %{value: integer(), children: [tree()]}

    @doc "Walk a tree."
    @spec walk(root :: tree()) :: :ok
    def walk(_root), do: :ok
  end
  """

  setup_all do
    {plain, _warnings} = compile_with_warnings!(@plain)
    {recursive, _warnings} = compile_with_warnings!(@recursive)

    %{plain: plain, recursive: recursive}
  end

  defp schema(module, target, opts \\ []) do
    module
    |> ToolCall.emit(target, opts)
    |> Enum.find(&(tool_name(&1, target) == "go"))
  end

  defp tool_name(%{"function" => %{"name" => name}}, :openai), do: name
  defp tool_name(%{"name" => name}, _target), do: name

  defp params(%{"function" => %{"parameters" => params}}), do: params
  defp params(%{"input_schema" => params}), do: params
  defp params(%{"inputSchema" => params}), do: params
  defp params(%{"parameters" => params}), do: params

  defp properties(schema), do: params(schema)["properties"]

  defp keys(term) do
    case term do
      map when is_map(map) ->
        Enum.flat_map(map, fn {key, value} -> [key | keys(value)] end)

      list when is_list(list) ->
        Enum.flat_map(list, &keys/1)

      _other ->
        []
    end
  end

  test "OpenAI keeps the shape and the constraints", %{plain: plain} do
    properties = plain |> schema(:openai) |> properties()

    assert %{"anyOf" => [%{"type" => "integer"}, %{"type" => "string"}]} =
             properties["union"]

    assert properties["count"]["minimum"] == 1
    assert properties["date"]["format"] == "date"
    assert properties["tags"]["minItems"] == 1

    assert properties["pair"]["prefixItems"] == [
             %{"type" => "integer"},
             %{"type" => "string"}
           ]

    assert properties["pair"]["minItems"] == 2
    assert properties["pair"]["maxItems"] == 2
    assert properties["meta"]["additionalProperties"] == true
    assert properties["note"]["properties"]["text"] == %{}
  end

  test "OpenAI strict keeps constraints but drops tuple positions", %{plain: plain} do
    properties = plain |> schema(:openai, strict: true) |> properties()

    assert properties["count"]["minimum"] == 1
    assert properties["date"]["format"] == "date"
    assert properties["tags"]["minItems"] == 1
    refute Map.has_key?(properties["pair"], "prefixItems")
    assert properties["pair"]["minItems"] == 2
    assert properties["pair"]["maxItems"] == 2
    assert properties["meta"]["additionalProperties"] == false
  end

  test "OpenAI fine-tuned drops constraints and tuple positions", %{plain: plain} do
    properties = plain |> schema(:openai, strict: :fine_tuned) |> properties()

    refute Map.has_key?(properties["count"], "minimum")
    refute Map.has_key?(properties["date"], "format")
    refute Map.has_key?(properties["tags"], "minItems")
    refute Map.has_key?(properties["pair"], "prefixItems")
    refute Map.has_key?(properties["pair"], "minItems")
    refute Map.has_key?(properties["pair"], "maxItems")
  end

  test "Anthropic and MCP keep the shared schema", %{plain: plain} do
    anthropic = plain |> schema(:anthropic) |> properties()
    mcp = plain |> schema(:mcp) |> properties()

    assert anthropic["count"]["minimum"] == 1
    assert anthropic["pair"]["prefixItems"]
    assert mcp["count"]["minimum"] == 1
    assert mcp["pair"]["prefixItems"]
  end

  test "MCP strict closes object properties", %{plain: plain} do
    properties = plain |> schema(:mcp, strict: true) |> properties()

    assert properties["meta"]["additionalProperties"] == false
  end

  test "Gemini drops what its OpenAPI subset cannot express", %{plain: plain} do
    properties = plain |> schema(:gemini) |> properties()

    refute Map.has_key?(properties["meta"], "additionalProperties")
    refute Map.has_key?(properties["pair"], "prefixItems")
    assert properties["pair"]["minItems"] == 2
    assert properties["pair"]["maxItems"] == 2
    assert properties["count"]["minimum"] == 1
  end

  test "Gemini rejects recursive $ref/$defs", %{recursive: recursive} do
    assert_raise ArgumentError, ~r/cannot express `\$ref`\/`\$defs`/, fn ->
      ToolCall.emit(recursive, :gemini)
    end
  end

  test "current emitters never emit allOf or not", %{plain: plain} do
    renderings = [
      ToolCall.emit(plain, :openai),
      ToolCall.emit(plain, :openai, strict: true),
      ToolCall.emit(plain, :openai, strict: :fine_tuned),
      ToolCall.emit(plain, :anthropic),
      ToolCall.emit(plain, :mcp),
      ToolCall.emit(plain, :mcp, strict: true),
      ToolCall.emit(plain, :gemini)
    ]

    for rendering <- renderings do
      keys = keys(rendering)
      refute "allOf" in keys
      refute "not" in keys
    end
  end
end
