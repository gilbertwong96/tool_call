defmodule ToolCall.TypeProviderTest.Money do
  @moduledoc false
  @enforce_keys [:amount]
  defstruct [:amount]
  @type t :: %__MODULE__{amount: String.t()}
end

defmodule ToolCall.TypeProviderTest.MoneyProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TypeProviderTest.Money, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :string, pattern: "^-?\\d+\\.\\d{2}$"}}
  end

  def resolve(_module, _function, _args), do: :error

  @impl true
  def coerce(value), do: {:ok, %ToolCall.TypeProviderTest.Money{amount: value}}
end

defmodule ToolCall.TypeProviderTest.Box do
  @moduledoc false
  @type t(value) :: [value]
end

defmodule ToolCall.TypeProviderTest.BoxProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TypeProviderTest.Box, :t, [item]) do
    {:ok, %ToolCall.IR.Type{kind: :array, items: item}}
  end

  def resolve(_module, _function, _args), do: :error
end

defmodule ToolCall.TypeProviderTest.AliasOnly do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.AliasProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TypeProviderTest.AliasOnly, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :string}}
  end

  def resolve(_module, _function, _args), do: :error
end

defmodule ToolCall.TypeProviderTest.Strict do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.StrictProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TypeProviderTest.Strict, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :string}}
  end

  def resolve(_module, _function, _args), do: :error

  @impl true
  def coerce("ok"), do: {:ok, :ok}
  def coerce(value), do: {:error, {:bad, value}}
end

defmodule ToolCall.TypeProviderTest.Weird do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.WeirdProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TypeProviderTest.Weird, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :string}}
  end

  def resolve(_module, _function, _args), do: :error

  @impl true
  def coerce(_value), do: :bogus
end

defmodule ToolCall.TypeProviderTest.Plain do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.Bad do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(_module, _function, _args), do: :bogus

  @impl true
  def coerce(value), do: {:ok, value}
end

defmodule ToolCall.TypeProviderTest.StringProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  # Built-ins win, so this must not be reached for String.t().
  @impl true
  def resolve(String, :t, []), do: {:ok, %ToolCall.IR.Type{kind: :integer}}
  def resolve(_module, _function, _args), do: :error
end

defmodule ToolCall.TypeProviderTest.RaiseType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.RaiseProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TypeProviderTest.RaiseType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :string}}
  end

  def resolve(_module, _function, _args), do: :error

  @impl true
  def coerce(_value), do: raise("provider boom")
end

defmodule ToolCall.TypeProviderTest.BadKindType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadPatternType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadPatternValueType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadTransformType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadFieldsType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadFieldType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadItemsType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadTupleType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadTupleElementType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadAdditionalType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadVariantsType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadValuesType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadMinimumType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadArrayMinimumType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadBoundOrderType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadArrayBoundType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadEnumValueType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadFormatType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadNullableType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.BadFieldMetadataType do
  @moduledoc false
  @type t :: String.t()
end

defmodule ToolCall.TypeProviderTest.NestedType do
  @moduledoc false
  @type t :: term()
end

defmodule ToolCall.TypeProviderTest.NestedProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  alias ToolCall.IR.{Field, Type}

  @impl true
  def resolve(ToolCall.TypeProviderTest.NestedType, :t, []) do
    {:ok,
     %Type{
       kind: :union,
       variants: [
         %Type{
           kind: :object,
           fields: [
             %Field{name: "value", key: :value, type: %Type{kind: :string}},
             %Field{
               name: "optional",
               key: :optional,
               type: %Type{kind: :integer},
               required: false
             }
           ],
           additional: %Type{kind: :any}
         },
         %Type{kind: :object, fields: nil, additional: nil},
         %Type{kind: :tuple, items: [%Type{kind: :string}]},
         %Type{kind: :tuple, items: nil},
         %Type{kind: :array, items: %Type{kind: :string}},
         %Type{kind: :array, items: nil},
         %Type{kind: :array, items: %Type{kind: :string, pattern: "^x$"}},
         %Type{kind: :enum, values: [:a, :b]},
         %Type{kind: :enum, values: nil},
         %Type{kind: :integer, minimum: 0, maximum: 10},
         %Type{kind: :float, minimum: 1.5, maximum: 2.5},
         %Type{kind: :array, items: %Type{kind: :string}, minimum: 1},
         %Type{kind: :enum, values: [nil, true, 1, "x", :a]},
         %Type{kind: :string, format: "date"},
         %Type{kind: :string, nullable: true}
       ]
     }}
  end

  def resolve(_module, _function, _args), do: :error
end

defmodule ToolCall.TypeProviderTest.InvalidProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TypeProviderTest.BadKindType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :bogus}}
  end

  def resolve(ToolCall.TypeProviderTest.BadPatternType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :string, pattern: "["}}
  end

  def resolve(ToolCall.TypeProviderTest.BadPatternValueType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :string, pattern: :not_a_string}}
  end

  def resolve(ToolCall.TypeProviderTest.BadTransformType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :string, transform: :bad}}
  end

  def resolve(ToolCall.TypeProviderTest.BadFieldsType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :object, fields: :bad}}
  end

  def resolve(ToolCall.TypeProviderTest.BadFieldType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :object, fields: [%ToolCall.IR.Field{name: "x", type: :bad}]}}
  end

  def resolve(ToolCall.TypeProviderTest.BadItemsType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :array, items: :bad}}
  end

  def resolve(ToolCall.TypeProviderTest.BadTupleType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :tuple, items: :bad}}
  end

  def resolve(ToolCall.TypeProviderTest.BadTupleElementType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :tuple, items: [:bad]}}
  end

  def resolve(ToolCall.TypeProviderTest.BadAdditionalType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :object, fields: [], additional: :bad}}
  end

  def resolve(ToolCall.TypeProviderTest.BadVariantsType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :union, variants: :bad}}
  end

  def resolve(ToolCall.TypeProviderTest.BadValuesType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :enum, values: :bad}}
  end

  def resolve(ToolCall.TypeProviderTest.BadMinimumType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :integer, minimum: :bad}}
  end

  def resolve(ToolCall.TypeProviderTest.BadArrayMinimumType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :array, minimum: -1}}
  end

  def resolve(ToolCall.TypeProviderTest.BadBoundOrderType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :integer, minimum: 10, maximum: 1}}
  end

  def resolve(ToolCall.TypeProviderTest.BadArrayBoundType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :array, minimum: 1.5}}
  end

  def resolve(ToolCall.TypeProviderTest.BadEnumValueType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :enum, values: [%{}]}}
  end

  def resolve(ToolCall.TypeProviderTest.BadFormatType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :string, format: :bad}}
  end

  def resolve(ToolCall.TypeProviderTest.BadNullableType, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :string, nullable: :bad}}
  end

  def resolve(ToolCall.TypeProviderTest.BadFieldMetadataType, :t, []) do
    {:ok,
     %ToolCall.IR.Type{
       kind: :object,
       fields: [
         %ToolCall.IR.Field{name: :bad, key: "bad", type: %ToolCall.IR.Type{kind: :string}}
       ]
     }}
  end

  def resolve(_module, _function, _args), do: :error
end

defmodule ToolCall.TypeProviderTest.Tools do
  @moduledoc false
  use ToolCall,
    types: [
      ToolCall.TypeProviderTest.MoneyProvider,
      ToolCall.TypeProviderTest.BoxProvider,
      ToolCall.TypeProviderTest.AliasProvider,
      ToolCall.TypeProviderTest.StrictProvider,
      ToolCall.TypeProviderTest.WeirdProvider,
      ToolCall.TypeProviderTest.StringProvider,
      ToolCall.TypeProviderTest.RaiseProvider
    ]

  @doc "Price."
  @spec price(amount :: ToolCall.TypeProviderTest.Money.t()) ::
          ToolCall.TypeProviderTest.Money.t()
  def price(amount), do: amount

  @doc "Boxes."
  @spec boxes(items :: ToolCall.TypeProviderTest.Box.t(integer())) :: list()
  def boxes(items), do: items

  @doc "Alias-only."
  @spec alias_only(value :: ToolCall.TypeProviderTest.AliasOnly.t()) :: String.t()
  def alias_only(value), do: value

  @doc "Strict."
  @spec strict(value :: ToolCall.TypeProviderTest.Strict.t()) :: atom()
  def strict(value), do: value

  @doc "Weird."
  @spec weird(value :: ToolCall.TypeProviderTest.Weird.t()) :: String.t()
  def weird(value), do: value

  @doc "Built-in string."
  @spec string_type(value :: String.t()) :: String.t()
  def string_type(value), do: value

  @doc "Raises in coerce."
  @spec raises(value :: ToolCall.TypeProviderTest.RaiseType.t()) :: String.t()
  def raises(value), do: value
end

defmodule ToolCall.TypeProviderTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  alias ToolCall.TypeProviderTest.{Money, Tools}

  test "resolves a custom type and coerces its value" do
    assert param_schema(Tools, "price", "amount") == %{
             "type" => "string",
             "pattern" => "^-?\\d+\\.\\d{2}$"
           }

    assert {:ok, %Money{amount: "12.34"}} =
             ToolCall.run(Tools, "price", %{"amount" => "12.34"})
  end

  test "expands aliases before resolving the provider" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: [ToolCall.TypeProviderTest.MoneyProvider]

        alias ToolCall.TypeProviderTest.Money, as: Cash

        @type amount :: Cash.t()

        @doc "Aliased."
        @spec go(value :: amount()) :: String.t()
        def go(value), do: value
      end
      """)

    assert param_schema(module, "go", "value") == %{
             "type" => "string",
             "pattern" => "^-?\\d+\\.\\d{2}$"
           }

    assert {:ok, %Money{amount: "12.34"}} =
             ToolCall.run(module, "go", %{"value" => "12.34"})
  end

  test "passes resolved argument types to the provider" do
    assert param_schema(Tools, "boxes", "items") == %{
             "type" => "array",
             "items" => %{"type" => "integer"}
           }

    assert {:ok, [1, 2]} = ToolCall.run(Tools, "boxes", %{"items" => [1, 2]})
  end

  test "supports remote types that are not structs" do
    assert param_schema(Tools, "alias_only", "value") == %{"type" => "string"}
    assert {:ok, "x"} = ToolCall.run(Tools, "alias_only", %{"value" => "x"})
  end

  test "wraps coerce errors like any other coercion failure" do
    assert {:error, {:invalid_argument, {"value", {:bad, "no"}}}} =
             ToolCall.run(Tools, "strict", %{"value" => "no"})

    assert {:ok, :ok} = ToolCall.run(Tools, "strict", %{"value" => "ok"})
  end

  test "rejects an unexpected coerce return" do
    assert {:error, {:invalid_argument, {"value", {:invalid_transform, :bogus}}}} =
             ToolCall.run(Tools, "weird", %{"value" => "x"})
  end

  test "stdlib transforms reject malformed values" do
    alias ToolCall.Providers.Stdlib

    assert {:error, {:expected_object, "x"}} = Stdlib.coerce_keyword("x")
    assert {:error, {:invalid_date, 1}} = Stdlib.coerce_date(1)
    assert {:error, {:invalid_time, 1}} = Stdlib.coerce_time(1)
    assert {:error, {:invalid_datetime, 1}} = Stdlib.coerce_datetime(1)
    assert {:error, {:invalid_naive_datetime, 1}} = Stdlib.coerce_naive_datetime(1)
  end

  test "built-in providers win" do
    assert param_schema(Tools, "string_type", "value") == %{"type" => "string"}
  end

  test "resolves %Struct{} syntax through a provider" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: [ToolCall.TypeProviderTest.MoneyProvider]

        @doc "Struct syntax."
        @spec go(value :: %ToolCall.TypeProviderTest.Money{}) :: String.t()
        def go(value), do: value
      end
      """)

    assert param_schema(module, "go", "value") == %{
             "type" => "string",
             "pattern" => "^-?\\d+\\.\\d{2}$"
           }

    assert {:ok, %Money{amount: "12.34"}} = ToolCall.run(module, "go", %{"value" => "12.34"})
  end

  test "a module type without a provider is not exposed" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Plain."
        @spec go(value :: ToolCall.TypeProviderTest.Plain.t()) :: String.t()
        def go(value), do: value
      end
      """)

    assert ToolCall.tools(module) == []
    assert warnings =~ ~s(tool "go" is not exposed: parameter "value")
  end

  test "raises when a provider returns an invalid value" do
    assert_raise ArgumentError, ~r/returned :bogus/, fn ->
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: [ToolCall.TypeProviderTest.BadProvider]

        @doc "Bad."
        @spec go(value :: ToolCall.TypeProviderTest.Bad.t()) :: :ok
        def go(_value), do: :ok
      end
      """)
    end
  end

  test "contains an exception raised by a provider coerce" do
    assert {:error,
            {:invalid_argument, {"value", {:invalid_transform, {:raised, "provider boom"}}}}} =
             ToolCall.run(Tools, "raises", %{"value" => "x"})
  end

  test "rejects a provider type with an unknown kind" do
    assert_raise ArgumentError, ~r/unknown kind :bogus/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadKindType
      )
    end
  end

  test "rejects a provider type with an uncompilable pattern" do
    assert_raise ArgumentError, ~r/does not compile/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadPatternType
      )
    end
  end

  test "rejects a provider type with a non-string pattern" do
    assert_raise ArgumentError, ~r/pattern must be a string/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadPatternValueType
      )
    end
  end

  test "rejects a provider type with a malformed transform" do
    assert_raise ArgumentError, ~r/transform must be nil or/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadTransformType
      )
    end
  end

  test "accepts a well-formed nested provider type" do
    module =
      compile_tool(
        ToolCall.TypeProviderTest.NestedProvider,
        ToolCall.TypeProviderTest.NestedType
      )

    assert [%{"function" => %{"name" => "go"}}] = ToolCall.emit(module, :openai)
  end

  test "compiles nested provider patterns into the IR" do
    type =
      ToolCall.Typespec.to_type(
        {{:., [], [ToolCall.TypeProviderTest.NestedType, :t]}, [], []},
        [ToolCall.TypeProviderTest.NestedProvider]
      )

    pattern =
      Enum.find(
        type.variants,
        &match?(
          %ToolCall.IR.Type{kind: :array, items: %ToolCall.IR.Type{pattern: "^x$"}},
          &1
        )
      )

    assert %ToolCall.IR.Type{pattern_regex: %Regex{}} = pattern.items
  end

  test "rejects a provider type with malformed fields" do
    assert_raise ArgumentError, ~r/fields must contain ToolCall.IR types/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadFieldsType
      )
    end
  end

  test "rejects a provider type with a malformed field" do
    assert_raise ArgumentError, ~r/field must have a string name/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadFieldType
      )
    end
  end

  test "rejects a provider type with malformed array items" do
    assert_raise ArgumentError, ~r/items must contain ToolCall.IR types/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadItemsType
      )
    end
  end

  test "rejects a provider type with malformed tuple items" do
    assert_raise ArgumentError, ~r/items must contain ToolCall.IR types/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadTupleType
      )
    end
  end

  test "rejects a provider type with a malformed tuple element" do
    assert_raise ArgumentError, ~r/nested type must contain ToolCall.IR types/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadTupleElementType
      )
    end
  end

  test "rejects a provider type with malformed additional values" do
    assert_raise ArgumentError, ~r/additional must contain ToolCall.IR types/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadAdditionalType
      )
    end
  end

  test "rejects a provider type with malformed variants" do
    assert_raise ArgumentError, ~r/variants must contain ToolCall.IR types/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadVariantsType
      )
    end
  end

  test "rejects a provider type with malformed enum values" do
    assert_raise ArgumentError, ~r/values must be a list or nil/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadValuesType
      )
    end
  end

  test "rejects a provider type with a malformed minimum" do
    assert_raise ArgumentError, ~r/minimum must be a number or nil/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadMinimumType
      )
    end
  end

  test "rejects a provider type with a negative array minimum" do
    assert_raise ArgumentError, ~r/array minimum must be >= 0/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadArrayMinimumType
      )
    end
  end

  test "rejects a provider type with reversed bounds" do
    assert_raise ArgumentError, ~r/minimum must be <= maximum/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadBoundOrderType
      )
    end
  end

  test "rejects a non-integer array bound" do
    assert_raise ArgumentError, ~r/array minimum must be an integer/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadArrayBoundType
      )
    end
  end

  test "rejects a provider enum with a non-scalar value" do
    assert_raise ArgumentError, ~r/enum values must be JSON scalars/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadEnumValueType
      )
    end
  end

  test "rejects a provider type with a malformed format" do
    assert_raise ArgumentError, ~r/format must be a string or nil/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadFormatType
      )
    end
  end

  test "rejects a provider type with a malformed nullable flag" do
    assert_raise ArgumentError, ~r/nullable must be a boolean/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadNullableType
      )
    end
  end

  test "rejects a provider type with malformed field metadata" do
    assert_raise ArgumentError, ~r/field must have a string name/, fn ->
      compile_tool(
        ToolCall.TypeProviderTest.InvalidProvider,
        ToolCall.TypeProviderTest.BadFieldMetadataType
      )
    end
  end

  test "validates the :types option" do
    assert_raise ArgumentError, ~r/:types must be a list/, fn ->
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: ToolCall.TypeProviderTest.MoneyProvider
      end
      """)
    end

    assert_raise ArgumentError, ~r/expected a module in :types/, fn ->
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: [123]
      end
      """)
    end

    assert_raise ArgumentError, ~r/expected a module in :types/, fn ->
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: [nil]
      end
      """)
    end

    assert_raise ArgumentError, ~r/accepts only :types/, fn ->
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: [], other: true
      end
      """)
    end
  end

  defp compile_tool(provider, type) do
    compile!("""
    defmodule FIXTURE do
      use ToolCall, types: [#{inspect(provider)}]

      @doc "Provider."
      @spec go(value :: #{inspect(type)}.t()) :: String.t()
      def go(value), do: value
    end
    """)
  end

  test "a provider may embed an argument that resolves to a struct" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: [ToolCall.TestFixtures.EmbedProvider]

        @doc "Go."
        @spec go(x :: ToolCall.TestFixtures.EmbedModule.t(ToolCall.TestFixtures.Address.t())) ::
                map()
        def go(x), do: x
      end
      """)

    [tool] = ToolCall.tools(module)
    [param] = tool.params

    assert %ToolCall.IR.Type{
             kind: :array,
             items: %ToolCall.IR.Type{kind: :object, struct: ToolCall.TestFixtures.Address}
           } = param.type
  end

  test "a provider exporting validate/1 gets a validator on the node it resolves" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: [ToolCall.TestFixtures.ValidatingProvider]

        @doc "Go."
        @spec go(x :: ToolCall.TestFixtures.ValidateModule.t()) :: map()
        def go(x), do: x
      end
      """)

    [tool] = ToolCall.tools(module)

    assert %ToolCall.IR.Type{validator: {ToolCall.TestFixtures.ValidatingProvider, :validate}} =
             hd(tool.params).type
  end

  test "a provider-typed result is validated end to end" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: [ToolCall.TestFixtures.ValidatingProvider]

        @doc "Good."
        @spec good(x :: integer()) :: ToolCall.TestFixtures.ValidateModule.t()
        def good(_x), do: "ok"

        @doc "Bad."
        @spec bad(x :: integer()) :: ToolCall.TestFixtures.ValidateModule.t()
        def bad(_x), do: 1
      end
      """)

    assert {:ok, "ok"} = ToolCall.run(module, :good, %{"x" => 1}, validate_result: true)

    assert {:error,
            {:invalid_result,
             {:validator, {ToolCall.TestFixtures.ValidatingProvider, :validate}, 1}}} =
             ToolCall.run(module, :bad, %{"x" => 1}, validate_result: true)
  end

  test "an explicit validator wins over the provider shorthand" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: [ToolCall.TestFixtures.PrecedenceProvider]

        @doc "Go."
        @spec go(x :: integer()) :: ToolCall.TestFixtures.PrecedenceModule.t()
        def go(_x), do: "ok"
      end
      """)

    [tool] = ToolCall.tools(module)

    assert %ToolCall.IR.Type{validator: {ToolCall.TestFixtures.RejectAll, :validate}} =
             tool.result

    assert {:error,
            {:invalid_result, {:validator, {ToolCall.TestFixtures.RejectAll, :validate}, "ok"}}} =
             ToolCall.run(module, :go, %{"x" => 1}, validate_result: true)
  end

  test "a provider validator that is not defined raises with provider context" do
    assert_raise ArgumentError,
                 ~r/type provider ToolCall.TestFixtures.BadValidatorProvider returned an invalid type for ToolCall.TestFixtures.MissingModule.t\/0: validator ToolCall.TestFixtures.NoSuchModule.validate\/3 is not defined/,
                 fn ->
                   compile!("""
                   defmodule ToolCall.TestFixtures.BadValidatorProvider do
                     @moduledoc false
                     @behaviour ToolCall.TypeProvider

                     @impl true
                     def resolve(ToolCall.TestFixtures.MissingModule, :t, []) do
                       {:ok,
                        %ToolCall.IR.Type{
                          kind: :string,
                          validator: {ToolCall.TestFixtures.NoSuchModule, :validate}
                        }}
                     end

                     def resolve(_module, _function, _args), do: :error
                   end

                   defmodule FIXTURE do
                     use ToolCall, types: [ToolCall.TestFixtures.BadValidatorProvider]

                     @doc "Go."
                     @spec go(x :: integer()) :: ToolCall.TestFixtures.MissingModule.t()
                     def go(_x), do: "ok"
                   end
                   """)
                 end
  end
end
