defmodule ToolCall.SchemaTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  alias ToolCall.Emit.Schema
  alias ToolCall.IR.{Field, Param, Tool, Type}

  describe "type/2" do
    test "renders numeric bounds for float and number" do
      assert Schema.type(%Type{kind: :float, minimum: 1.5, maximum: 2.5}) == %{
               "type" => "number",
               "minimum" => 1.5,
               "maximum" => 2.5
             }

      assert Schema.type(%Type{kind: :number, minimum: 1}) == %{
               "type" => "number",
               "minimum" => 1
             }
    end

    test "renders numeric scalars" do
      assert Schema.type(%Type{kind: :float}) == %{"type" => "number"}
      assert Schema.type(%Type{kind: :number}) == %{"type" => "number"}

      assert Schema.type(%Type{kind: :integer, maximum: -1}) == %{
               "type" => "integer",
               "maximum" => -1
             }
    end

    test "a nullable unconstrained type gets a null branch" do
      assert Schema.type(%Type{kind: :any, nullable: true}) == %{
               "anyOf" => [%{}, %{"type" => "null"}]
             }
    end

    test "renders unconstrained shapes as an empty schema" do
      assert Schema.type(%Type{kind: :any}) == %{}
      assert Schema.type(%Type{kind: :unsupported}) == %{}
    end

    test "calendar strings carry the format the API understands" do
      assert Schema.type(%Type{kind: :string, format: "date"}) == %{
               "type" => "string",
               "format" => "date"
             }

      assert Schema.type(%Type{kind: :string, format: "time"})["format"] == "time"
      assert Schema.type(%Type{kind: :string, format: "date-time"})["format"] == "date-time"
      assert Schema.type(%Type{kind: :string}) == %{"type" => "string"}
    end

    test "renders null" do
      assert Schema.type(%Type{kind: :null}) == %{"type" => "null"}
    end

    test "a hand-built nil enum keeps null" do
      assert Schema.type(%Type{kind: :enum, values: [nil]}) == %{"enum" => [nil]}
    end

    test "boolean literals render as a boolean enum" do
      assert Schema.type(%Type{kind: :enum, values: [true]}) == %{
               "type" => "boolean",
               "enum" => [true]
             }
    end

    test "a boolean mixed with an atom keeps both types" do
      assert Schema.type(%Type{kind: :enum, values: [true, :a]}) == %{"enum" => [true, :a]}
    end

    test "an enum without values is a bare string" do
      assert Schema.type(%Type{kind: :enum, values: nil}) == %{"type" => "string"}
      assert Schema.type(%Type{kind: :enum, values: []}) == %{"type" => "string"}
    end

    test "a mixed enum carries no type" do
      assert Schema.type(%Type{kind: :enum, values: [:red, 1]}) == %{"enum" => [:red, 1]}
    end

    test "a nullable enum accepts null" do
      # JSON Schema validates `enum` independently of `type`, so widening the
      # type is not enough: null needs its own branch.
      assert Schema.type(%Type{kind: :enum, values: [:red], nullable: true}) == %{
               "anyOf" => [%{"type" => "string", "enum" => ["red"]}, %{"type" => "null"}]
             }
    end

    test "strict mode drops defaults, which the API rejects" do
      param = %Param{
        name: "days",
        type: %Type{kind: :integer, minimum: 1},
        required: false,
        default: 3
      }

      tool = %Tool{name: "go", description: "Go.", params: [param]}

      assert Schema.params(tool, strict: true)["properties"]["days"] == %{
               "type" => ["integer", "null"],
               "minimum" => 1
             }

      assert Schema.params(tool)["properties"]["days"]["default"] == 3
    end

    test "strict mode keeps a tuple's arity but drops its positions" do
      type = %Type{kind: :tuple, items: [%Type{kind: :integer}, %Type{kind: :string}]}

      assert Schema.type(type, strict: true) == %{
               "type" => "array",
               "items" => %{},
               "minItems" => 2,
               "maxItems" => 2
             }

      assert Schema.type(type)["prefixItems"] == [%{"type" => "integer"}, %{"type" => "string"}]
    end

    test "strict mode requires every field of a nested object" do
      type = %Type{
        kind: :object,
        fields: [
          %Field{name: "a", type: %Type{kind: :string}, required: false},
          %Field{name: "b", type: %Type{kind: :integer}}
        ]
      }

      assert Schema.type(type, strict: true) == %{
               "type" => "object",
               "properties" => %{
                 "a" => %{"type" => ["string", "null"]},
                 "b" => %{"type" => "integer"}
               },
               "required" => ["a", "b"],
               "additionalProperties" => false
             }
    end

    test "an unconstrained tuple renders an array with unconstrained items" do
      assert Schema.type(%Type{kind: :tuple, items: nil}) == %{
               "type" => "array",
               "items" => %{}
             }

      assert Schema.type(%Type{kind: :tuple, items: nil}, strict: true) == %{
               "type" => "array",
               "items" => %{}
             }
    end

    test "an array without items renders an open item schema" do
      assert Schema.type(%Type{kind: :array}) == %{"type" => "array", "items" => %{}}
    end

    test "renders array bounds" do
      type = %Type{kind: :array, items: %Type{kind: :integer}, minimum: 1, maximum: 3}

      assert Schema.type(type) == %{
               "type" => "array",
               "items" => %{"type" => "integer"},
               "minItems" => 1,
               "maxItems" => 3
             }
    end

    test "a nullable anyOf gets a null variant" do
      type = %Type{
        kind: :union,
        variants: [%Type{kind: :integer}],
        nullable: true
      }

      assert Schema.type(type) == %{
               "anyOf" => [%{"type" => "integer"}, %{"type" => "null"}]
             }
    end
  end

  describe "string integers" do
    test "keep null when the domain is nullable" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Nullable id."
          @tool_param %{fun: :go, name: "id", wire: :string_integer}
          @spec go(id :: integer() | nil) :: :ok
          def go(_id), do: :ok
        end
        """)

      assert param_schema(module, "go", "id") == %{
               "type" => ["string", "null"],
               "pattern" => "^-?\\d+$"
             }
    end

    test "renders an integer default as a string" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Id."
          @tool_param %{fun: :go, name: "id", wire: :string_integer}
          @spec go(id :: integer()) :: integer()
          def go(id \\\\42), do: id
        end
        """)

      assert param_schema(module, "go", "id") == %{
               "type" => "string",
               "pattern" => "^-?\\d+$",
               "default" => "42"
             }
    end
  end

  test "renders a char default as a string" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(c :: char()) :: char()
        def go(c \\\\ ?a), do: c
      end
      """)

    assert param_schema(module, "go", "c") == %{
             "type" => "string",
             "pattern" => "^[\\s\\S]$",
             "default" => "a"
           }
  end

  test "only renders char defaults that are valid characters" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec int(c :: char()) :: char()
        def int(c \\\\ ?a), do: c

        @spec bin(c :: char()) :: char()
        def bin(c \\\\ "a"), do: c

        @spec bad_bin(c :: char()) :: char()
        def bad_bin(c \\\\ "ab"), do: c

        @spec surrogate(c :: char()) :: char()
        def surrogate(c \\\\ 0xD800), do: c

        @spec negative(c :: char()) :: char()
        def negative(c \\\\ -1), do: c
      end
      """)

    assert param_schema(module, "int", "c")["default"] == "a"
    assert param_schema(module, "bin", "c")["default"] == "a"
    refute Map.has_key?(param_schema(module, "bad_bin", "c"), "default")
    refute Map.has_key?(param_schema(module, "surrogate", "c"), "default")
    refute Map.has_key?(param_schema(module, "negative", "c"), "default")
  end

  test "omits a char default that is not valid utf-8" do
    tool = %Tool{
      name: "go",
      params: [
        %Param{
          name: "c",
          type: %Type{kind: :string, source: :char, pattern: "^[\\s\\S]$"},
          default: <<255>>
        }
      ]
    }

    refute Map.has_key?(Schema.params(tool)["properties"]["c"], "default")
  end

  test "rejects an empty non-nullable union before rendering" do
    assert_raise ArgumentError, ~r/variants/, fn ->
      Schema.type(%Type{kind: :union, variants: []})
    end

    assert Schema.type(%Type{kind: :union, variants: [], nullable: true}) == %{
             "anyOf" => [%{"type" => "null"}]
           }
  end

  test "strict mode keeps a nullable null as a single null type" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(x :: nil) :: nil
        def go(x \\\\ nil), do: x
      end
      """)

    assert param_schema(module, "go", "x") == %{"type" => "null"}

    assert module
           |> ToolCall.emit(:openai, strict: true)
           |> hd()
           |> get_in(["function", "parameters", "properties", "x"]) == %{"type" => "null"}
  end

  test "a default tuple of the wrong size is kept as is" do
    param = %Param{
      name: "t",
      type: %Type{kind: :tuple, items: [%Type{kind: :atom}, %Type{kind: :atom}]},
      default: [true],
      required: true
    }

    tool = %Tool{name: "go", description: "Go.", params: [param]}
    assert Schema.params(tool)["properties"]["t"]["default"] == [true]
  end

  test "emitters default their options" do
    tool = %Tool{name: "go", description: "Go.", params: []}

    assert ToolCall.Emit.OpenAI.emit(tool)["type"] == "function"
    assert ToolCall.Emit.Anthropic.emit(tool)["name"] == "go"
  end

  test "raises for an unsupported target on a runtime tool" do
    tool = %Tool{name: "go", description: "Go.", params: []}

    assert_raise ArgumentError, ~r/unsupported target/, fn ->
      ToolCall.emit(tool, :gemini)
    end
  end

  test "a runtime tool may omit or nil its params" do
    tool = %Tool{name: "go", description: "Go."}

    expected = %{
      "type" => "object",
      "properties" => %{},
      "required" => [],
      "additionalProperties" => false
    }

    assert ToolCall.emit(tool, :openai)["function"]["parameters"] == expected
    assert ToolCall.emit(%{tool | params: nil}, :openai)["function"]["parameters"] == expected
  end

  test "validates runtime tool types before rendering" do
    tool = %Tool{
      name: "bad",
      params: [%Param{name: "value", type: %Type{kind: :bogus}}]
    }

    assert_raise ArgumentError, ~r/invalid ToolCall IR: unknown kind :bogus/, fn ->
      ToolCall.emit(tool, :openai)
    end
  end

  test "rejects a non-Type runtime IR param" do
    tool = %Tool{name: "bad", params: [%Param{name: "value", type: :bad}]}

    assert_raise ArgumentError, ~r/expected a type, got: :bad/, fn ->
      ToolCall.emit(tool, :openai)
    end
  end

  test "rejects a runtime tool with a non-string name" do
    tool = %Tool{name: :bad, params: []}

    assert_raise ArgumentError, ~r/tool name must be a string/, fn ->
      ToolCall.emit(tool, :openai)
    end
  end

  test "rejects a runtime parameter with invalid metadata" do
    tool = %Tool{name: "bad", params: [%Param{name: :bad, type: %Type{kind: :string}}]}

    assert_raise ArgumentError, ~r/invalid parameter/, fn ->
      ToolCall.emit(tool, :openai)
    end
  end

  test "rejects a runtime tool with an invalid description" do
    tool = %Tool{name: "bad", description: :bad, params: []}

    assert_raise ArgumentError, ~r/tool description must be a string/, fn ->
      ToolCall.emit(tool, :openai)
    end
  end

  test "rejects a runtime parameter with an invalid description" do
    tool = %Tool{
      name: "bad",
      params: [%Param{name: "value", type: %Type{kind: :string}, description: :bad}]
    }

    assert_raise ArgumentError, ~r/parameter description must be a string/, fn ->
      ToolCall.emit(tool, :openai)
    end
  end

  test "rejects a runtime parameter with a non-JSON default" do
    tool = %Tool{
      name: "bad",
      params: [
        %Param{
          name: "value",
          type: %Type{kind: :string},
          default: ~D[2024-01-01]
        }
      ]
    }

    assert_raise ArgumentError, ~r/default must be JSON-encodable/, fn ->
      ToolCall.emit(tool, :openai)
    end
  end

  test "validates runtime tools through Emit directly" do
    tool = %Tool{name: "bad", params: [%Param{name: "value", type: %Type{kind: :bogus}}]}

    assert_raise ArgumentError, ~r/invalid ToolCall IR: unknown kind/, fn ->
      ToolCall.Emit.emit(tool, :openai)
    end
  end

  test "treats a nil strict option as false" do
    assert Schema.strict?(strict: nil) == false
    assert Schema.strict?(strict: true) == true
    assert Schema.strict?([]) == false

    assert_raise ArgumentError, ~r/strict must be a boolean/, fn ->
      Schema.strict?(strict: :yes)
    end
  end
end
