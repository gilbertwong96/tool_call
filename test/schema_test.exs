defmodule ToolCall.SchemaTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  alias ToolCall.Emit.Schema
  alias ToolCall.IR.{Field, Param, Tool, Type}

  describe "type/2" do
    test "renders numeric scalars" do
      assert Schema.type(%Type{kind: :float}) == %{"type" => "number"}
      assert Schema.type(%Type{kind: :number}) == %{"type" => "number"}

      assert Schema.type(%Type{kind: :integer, maximum: -1}) == %{
               "type" => "integer",
               "maximum" => -1
             }
    end

    test "renders unconstrained shapes as an empty schema" do
      assert Schema.type(%Type{kind: :any}) == %{}
      assert Schema.type(%Type{kind: :unsupported}) == %{}
    end

    test "calendar strings carry the format the API understands" do
      assert Schema.type(%Type{kind: :string, source: {Date, :t}}) == %{
               "type" => "string",
               "format" => "date"
             }

      assert Schema.type(%Type{kind: :string, source: {Time, :t}})["format"] == "time"
      assert Schema.type(%Type{kind: :string, source: {DateTime, :t}})["format"] == "date-time"

      assert Schema.type(%Type{kind: :string, source: {NaiveDateTime, :t}}) == %{
               "type" => "string"
             }
    end

    test "renders null" do
      assert Schema.type(%Type{kind: :null}) == %{"type" => "null"}
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

    test "an array without items renders an open item schema" do
      assert Schema.type(%Type{kind: :array}) == %{"type" => "array", "items" => %{}}
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

  test "treats a nil strict option as false" do
    assert Schema.strict?(strict: nil) == false
    assert Schema.strict?(strict: true) == true
    assert Schema.strict?([]) == false

    assert_raise ArgumentError, ~r/strict must be a boolean/, fn ->
      Schema.strict?(strict: :yes)
    end
  end
end
