defmodule ToolCall.EmitTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  defp tool(module, name, target \\ :openai, opts \\ []) do
    module
    |> ToolCall.emit(target, opts)
    |> List.wrap()
    |> Enum.find(&(&1["function"]["name"] == name || &1["name"] == name))
  end

  defp properties(module, name, opts \\ []) do
    tool(module, name, :openai, opts)["function"]["parameters"]["properties"]
  end

  test "rejects a strict value that is not a boolean" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(x :: integer()) :: :ok
        def go(_x), do: :ok
      end
      """)

    assert_raise ArgumentError, ~r/strict must be a boolean/, fn ->
      ToolCall.emit(module, :openai, strict: "true")
    end

    assert_raise ArgumentError, ~r/strict must be a boolean/, fn ->
      ToolCall.emit(module, :anthropic, strict: :yes)
    end
  end

  describe "openai strict mode" do
    test "marks the tool object as strict" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Strict."
          @spec go(x :: integer()) :: :ok
          def go(_x), do: :ok
        end
        """)

      assert %{"strict" => true} = tool(module, "go", :openai, strict: true)
    end

    test "closes open objects, which the strict schema subset requires" do
      {module, _warning} =
        compile_with_warnings!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Open map."
          @spec go(m :: map(), l :: list(map())) :: :ok
          def go(_m, _l), do: :ok
        end
        """)

      assert %{
               "m" => %{"additionalProperties" => false},
               "l" => %{"items" => %{"additionalProperties" => false}}
             } = properties(module, "go", strict: true)
    end

    test "warn at compile time, once, not on every emit" do
      {module, warnings} =
        compile_with_warnings!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Untyped."
          @spec go(a :: term(), b :: list(term())) :: :ok
          def go(_a, _b), do: :ok
        end
        """)

      assert warnings =~ ~s(parameter "a" of go/2 has no JSON type)
      assert warnings =~ ~s(parameter "b" of go/2 has no JSON type)

      {_schema, diagnostics} =
        Code.with_diagnostics(fn -> tool(module, "go", :openai, strict: true) end)

      assert diagnostics == []
    end

    test "say nothing when every parameter is typed" do
      {_module, warnings} =
        compile_with_warnings!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Typed."
          @spec go(a :: String.t()) :: :ok
          def go(_a), do: :ok
        end
        """)

      assert warnings == ""
    end

    test "makes optional arguments required and nullable" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Optional."
          @spec go(a :: String.t(), b :: integer()) :: :ok
          def go(a, b \\\\ 3), do: {a, b}
        end
        """)

      parameters = tool(module, "go", :openai, strict: true)["function"]["parameters"]

      assert parameters["required"] == ["a", "b"]
      assert parameters["properties"]["b"]["type"] == ["integer", "null"]
    end
  end

  describe "anthropic" do
    test "ignores the openai-only :strict option" do
      {module, _warning} =
        compile_with_warnings!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Open map."
          @spec go(m :: map()) :: :ok
          def go(_m), do: :ok
        end
        """)

      schema = tool(module, "go", :anthropic, strict: true)

      assert schema["input_schema"]["properties"]["m"]["additionalProperties"] == true
    end
  end

  describe "precompiled schemas" do
    test "are embedded as a literal and agree with a fresh render" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "One."
          @spec one(a :: String.t(), b :: pos_integer() | nil) :: :ok
          def one(_a, _b \\\\ 1), do: :ok
        end
        """)

      assert %{
               {:openai, false} => openai,
               {:openai, true} => openai_strict,
               {:anthropic, false} => anthropic
             } = module.__schemas__()

      ir = ToolCall.tools(module)
      assert openai == ToolCall.Emit.emit(ir, :openai)
      assert openai_strict == ToolCall.Emit.emit(ir, :openai, strict: true)
      assert anthropic == ToolCall.Emit.emit(ir, :anthropic)

      assert ToolCall.emit(module, :openai) == openai
      assert ToolCall.emit(module, :openai, strict: true) == openai_strict
      assert ToolCall.emit(module, :anthropic) == anthropic
    end

    test "pick the variant from a runtime boolean" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Optional."
          @spec one(a :: String.t(), b :: integer()) :: :ok
          def one(_a, b \\\\ 1), do: b
        end
        """)

      schemas = module.__schemas__()

      for strict <- [false, true] do
        assert ToolCall.emit(module, :openai, strict: strict) ==
                 schemas[{:openai, strict}]
      end

      refute schemas[{:openai, true}] == schemas[{:openai, false}]
    end

    test "anthropic ignores :strict, so both flags hit the same literal" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "One."
          @spec one(a :: String.t()) :: :ok
          def one(_a), do: :ok
        end
        """)

      assert ToolCall.emit(module, :anthropic, strict: true) ==
               ToolCall.emit(module, :anthropic)
    end
  end

  describe "targets" do
    test "emits a list for a module and a map for the IR" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "One."
          @spec one() :: :ok
          def one, do: :ok

          @doc "Two."
          @spec two() :: :ok
          def two, do: :ok
        end
        """)

      assert [%{"type" => "function"}, %{"type" => "function"}] =
               ToolCall.emit(module, :openai)

      assert %{"name" => "one", "input_schema" => %{"type" => "object"}} =
               ToolCall.emit(module, :anthropic) |> List.first()

      ir_tool = module |> ToolCall.tools() |> List.first()
      assert %{"type" => "function"} = ToolCall.emit(ir_tool, :openai)
    end

    test "raises a clear error for an unknown target" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "One."
          @spec one() :: :ok
          def one, do: :ok
        end
        """)

      assert_raise ArgumentError, ~r/unsupported target/, fn ->
        ToolCall.emit(module, :gemini)
      end
    end
  end

  describe "descriptions" do
    test "fall back to the tool name when there is no @doc" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @spec go(x :: integer()) :: :ok
          def go(_x), do: :ok
        end
        """)

      assert tool(module, "go")["function"]["description"] == "go"
      assert tool(module, "go", :anthropic)["description"] == "go"
    end
  end

  describe "type rendering" do
    setup do
      {module, _warnings} =
        compile_with_warnings!("""
        defmodule FIXTURE do
          use ToolCall

          @spec types(
                  u :: integer() | String.t(),
                  t :: {integer(), String.t()},
                  c :: char(),
                  e :: :red | :green,
                  i :: 1 | 2,
                  n :: nil,
                  a :: atom(),
                  l :: nonempty_list(byte()),
                  o :: map(),
                  k :: keyword(integer())
                ) :: :ok
          def types(_u, _t, _c, _e, _i, _n, _a, _l, _o, _k), do: :ok
        end
        """)

      %{properties: properties(module, "types")}
    end

    test "unions become anyOf", %{properties: properties} do
      assert properties["u"] == %{
               "anyOf" => [%{"type" => "integer"}, %{"type" => "string"}]
             }
    end

    test "tuples become prefixItems with a fixed size", %{properties: properties} do
      assert properties["t"] == %{
               "type" => "array",
               "prefixItems" => [%{"type" => "integer"}, %{"type" => "string"}],
               "minItems" => 2,
               "maxItems" => 2
             }
    end

    test "char carries a single-character pattern", %{properties: properties} do
      assert properties["c"] == %{"type" => "string", "pattern" => "^[\\s\\S]$"}
    end

    test "atom enums render as strings", %{properties: properties} do
      assert properties["e"] == %{"type" => "string", "enum" => ["red", "green"]}
    end

    test "integer enums carry their type", %{properties: properties} do
      assert properties["i"] == %{"type" => "integer", "enum" => [1, 2]}
    end

    test "nil becomes a null type", %{properties: properties} do
      assert properties["n"] == %{"type" => "null"}
    end

    test "atom becomes an unconstrained string", %{properties: properties} do
      assert properties["a"] == %{"type" => "string"}
    end

    test "non-empty lists carry minItems and byte bounds", %{properties: properties} do
      assert properties["l"] == %{
               "type" => "array",
               "items" => %{"type" => "integer", "minimum" => 0, "maximum" => 255},
               "minItems" => 1
             }
    end

    test "open maps allow additional properties", %{properties: properties} do
      assert properties["o"] == %{
               "type" => "object",
               "properties" => %{},
               "required" => [],
               "additionalProperties" => true
             }
    end

    test "keyword lists keep their value type", %{properties: properties} do
      assert properties["k"] == %{
               "type" => "object",
               "properties" => %{},
               "required" => [],
               "additionalProperties" => %{"type" => "integer"}
             }
    end
  end

  describe "nested objects" do
    test "render properties, required keys and a closed shape" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Nested."
          @spec go(m :: %{optional(:age) => integer(), required(:name) => String.t()}) :: :ok
          def go(_m), do: :ok
        end
        """)

      assert %{
               "properties" => %{
                 "name" => %{"type" => "string"},
                 "age" => %{"type" => "integer"}
               },
               "required" => ["name"],
               "additionalProperties" => false
             } = properties(module, "go")["m"]
    end
  end

  describe "nullable" do
    test "adds null to a scalar type" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Nullable."
          @spec go(s :: String.t() | nil) :: :ok
          def go(_s), do: :ok
        end
        """)

      assert properties(module, "go")["s"] == %{"type" => ["string", "null"]}
    end

    test "adds a null variant to a union" do
      module =
        compile!("""
        defmodule FIXTURE do
          use ToolCall

          @doc "Nullable union."
          @spec go(u :: integer() | String.t() | nil) :: :ok
          def go(_u), do: :ok
        end
        """)

      assert properties(module, "go")["u"] == %{
               "anyOf" => [
                 %{"type" => "integer"},
                 %{"type" => "string"},
                 %{"type" => "null"}
               ]
             }
    end
  end
end
