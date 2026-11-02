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

defmodule ToolCall.TypeProviderTest.Tools do
  @moduledoc false
  use ToolCall,
    types: [
      ToolCall.TypeProviderTest.MoneyProvider,
      ToolCall.TypeProviderTest.BoxProvider,
      ToolCall.TypeProviderTest.AliasProvider,
      ToolCall.TypeProviderTest.StrictProvider,
      ToolCall.TypeProviderTest.WeirdProvider,
      ToolCall.TypeProviderTest.StringProvider
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

  test "a struct without a provider falls back to any" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Plain."
        @spec go(value :: ToolCall.TypeProviderTest.Plain.t()) :: String.t()
        def go(value), do: value
      end
      """)

    assert param_schema(module, "go", "value") == %{}
    assert {:ok, "x"} = ToolCall.run(module, "go", %{"value" => "x"})
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

    assert_raise ArgumentError, ~r/accepts only :types/, fn ->
      compile!("""
      defmodule FIXTURE do
        use ToolCall, types: [], other: true
      end
      """)
    end
  end
end
