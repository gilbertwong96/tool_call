defmodule ToolCall.GeminiEmitTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  alias ToolCall.IR.{Param, Tool, Type}

  defp declaration(source) do
    module = compile!(source)
    [declaration] = ToolCall.emit(module, :gemini)
    declaration
  end

  test "uses uppercase types and drops additionalProperties" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Find a city."
        @spec find(city :: String.t(), days :: pos_integer()) :: map()
        def find(_city, _days), do: %{}
      end
      """)

    assert declaration["name"] == "find"
    assert declaration["description"] == "Find a city."

    assert %{
             "type" => "OBJECT",
             "properties" => %{
               "city" => %{"type" => "STRING"},
               "days" => %{"type" => "INTEGER", "minimum" => 1}
             },
             "required" => ["city", "days"]
           } = declaration["parameters"]

    refute Map.has_key?(declaration["parameters"], "additionalProperties")
  end

  test "a nullable value becomes nullable: true" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Find."
        @spec find(days :: integer() | nil) :: map()
        def find(_days), do: %{}
      end
      """)

    assert %{"type" => "INTEGER", "nullable" => true} =
             declaration["parameters"]["properties"]["days"]
  end

  test "string enums become a format: enum" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Paint."
        @spec paint(color :: :red | :green) :: :ok
        def paint(_color), do: :ok
      end
      """)

    assert %{"type" => "STRING", "enum" => ["red", "green"], "format" => "enum"} =
             declaration["parameters"]["properties"]["color"]
  end

  test "non-string enums keep the type and drop the enum" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Flag."
        @spec flag(on :: true | false) :: :ok
        def flag(_on), do: :ok
      end
      """)

    assert %{"type" => "BOOLEAN"} = declaration["parameters"]["properties"]["on"]
    refute Map.has_key?(declaration["parameters"]["properties"]["on"], "enum")
  end

  test "a tuple loses positions and keeps the size bounds" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Pair."
        @spec pair(pair :: {integer(), String.t()}) :: :ok
        def pair(_pair), do: :ok
      end
      """)

    property = declaration["parameters"]["properties"]["pair"]
    assert %{"type" => "ARRAY", "minItems" => 2, "maxItems" => 2, "items" => %{}} = property
    refute Map.has_key?(property, "prefixItems")
  end

  test "an open object loses additionalProperties" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Map."
        @spec map(opts :: map()) :: :ok
        def map(_opts), do: :ok
      end
      """)

    property = declaration["parameters"]["properties"]["opts"]
    assert %{"type" => "OBJECT"} = property
    refute Map.has_key?(property, "additionalProperties")
  end

  test "a calendar format is kept" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        use ToolCall

        @doc "At."
        @spec at(at :: Date.t()) :: :ok
        def at(_at), do: :ok
      end
      """)

    assert %{"type" => "STRING", "format" => "date"} =
             declaration["parameters"]["properties"]["at"]
  end

  test "a tool with no parameters still carries an object schema" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Ping."
        @spec ping() :: :ok
        def ping, do: :ok
      end
      """)

    assert %{"type" => "OBJECT", "properties" => %{}, "required" => []} =
             declaration["parameters"]
  end

  test "a recursive parameter raises instead of emitting $ref" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @type tree :: %{value: integer(), children: [tree()]}

        @doc "Walk."
        @spec walk(root :: tree()) :: :ok
        def walk(_root), do: :ok
      end
      """)

    assert_raise ArgumentError, ~r/\$ref/, fn ->
      ToolCall.emit(module, :gemini)
    end
  end

  test "renders a runtime tool on demand" do
    tool = %Tool{
      name: "go",
      description: "Go.",
      params: [%Param{name: "x", type: %Type{kind: :integer}}]
    }

    assert %{
             "name" => "go",
             "description" => "Go.",
             "parameters" => %{"properties" => %{"x" => %{"type" => "INTEGER"}}}
           } = ToolCall.emit(tool, :gemini)
  end

  test "ignores strict but validates the option shape" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @spec go(x :: integer()) :: :ok
        def go(_x), do: :ok
      end
      """)

    assert ToolCall.emit(module, :gemini, strict: true) == ToolCall.emit(module, :gemini)

    assert_raise ArgumentError, ~r/strict must be a boolean/, fn ->
      ToolCall.emit(module, :gemini, strict: :yes)
    end
  end
end
