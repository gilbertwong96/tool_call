defmodule ToolCallTest.Weather do
  @moduledoc false
  use ToolCall

  @doc """
  Get the forecast for a city.

  ## Parameters
    * `city` - city name
    * `days` - how many days ahead
  """
  @spec get_weather(city :: String.t(), days :: pos_integer() | nil) ::
          {:ok, %{temp: float()}} | {:error, String.t()}
  def get_weather(city, days \\ 3), do: {:ok, %{city: city, days: days, temp: 21.5}}

  @spec add(a :: integer(), b :: integer()) :: integer()
  def add(a, b), do: a + b

  @tool_param %{fun: :big_id, name: "user_id", wire: :string_integer, description: "Snowflake id"}
  @spec big_id(user_id :: integer()) :: String.t()
  def big_id(user_id), do: Integer.to_string(user_id)

  @spec set_temp(value :: float()) :: float()
  def set_temp(value), do: value

  @spec paint(color :: :red | :green) :: :ok
  def paint(_color), do: :ok

  @spec boom(x :: integer()) :: integer()
  def boom(_x), do: raise("kaboom")

  @doc false
  @spec hidden(x :: integer()) :: integer()
  def hidden(x), do: x
end

defmodule ToolCallTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias ToolCallTest.Weather

  describe "compile-time derivation" do
    test "collects public, documented functions in declaration order" do
      assert ToolCall.tool_names(Weather) ==
               ["get_weather", "add", "big_id", "set_temp", "paint", "boom"]
    end

    test "embeds type provenance but drops spec provenance" do
      tool = Weather.__tool__("get_weather")

      assert tool.source == nil
      assert Enum.all?(tool.params, &(&1.source == nil))
      assert Enum.any?(tool.params, &(&1.type.source != nil))
    end

    test "drops @doc false functions" do
      refute Enum.any?(ToolCall.tools(Weather), &(&1.name == "hidden"))
    end

    test "reads the description from the first @doc paragraph" do
      assert Weather.__tool__("get_weather").description == "Get the forecast for a city."
    end

    test "reads parameter descriptions from the ## Parameters bullets" do
      params = Weather.__tool__("get_weather").params

      assert Enum.map(params, & &1.name) == ["city", "days"]
      assert Enum.map(params, & &1.description) == ["city name", "how many days ahead"]
    end

    test "treats a parameter with a default as optional" do
      [city, days] = Weather.__tool__("get_weather").params

      assert city.required
      refute days.required
      assert days.default == 3
    end
  end

  describe "describe/2" do
    test "returns provider-neutral specs in declaration order" do
      assert [
               %{
                 module: Weather,
                 name: "get_weather",
                 description: "Get the forecast for a city."
               }
               | _
             ] =
               ToolCall.describe(Weather)

      assert ToolCall.describe(Weather) |> Enum.map(& &1.name) == ToolCall.tool_names(Weather)
    end

    test "carries the parameters object without an envelope" do
      spec = Enum.find(ToolCall.describe(Weather), &(&1.name == "get_weather"))

      assert %{"type" => "object", "properties" => properties} = spec.parameters
      assert properties["city"] == %{"type" => "string", "description" => "city name"}
    end

    test "renders the strict subset on request" do
      spec = Weather |> ToolCall.describe() |> Enum.find(&(&1.name == "get_weather"))
      assert spec.parameters["required"] == ["city"]

      strict =
        Weather |> ToolCall.describe(strict: true) |> Enum.find(&(&1.name == "get_weather"))

      assert strict.parameters["required"] == ["city", "days"]
    end
  end

  describe "module guards" do
    test "rejects modules that do not use ToolCall" do
      assert_raise ArgumentError, ~r/does not use ToolCall/, fn ->
        ToolCall.tools(String)
      end

      assert_raise ArgumentError, ~r/does not use ToolCall/, fn ->
        ToolCall.emit(String, :openai)
      end

      assert_raise ArgumentError, ~r/does not use ToolCall/, fn ->
        ToolCall.run(String, :upcase, %{})
      end
    end
  end

  describe "schema emission" do
    test "emits an OpenAI function definition" do
      schema = openai("get_weather")

      assert %{"type" => "function", "function" => function} = schema
      assert function["description"] == "Get the forecast for a city."

      assert function["parameters"] == %{
               "type" => "object",
               "properties" => %{
                 "city" => %{"type" => "string", "description" => "city name"},
                 "days" => %{
                   "type" => ["integer", "null"],
                   "minimum" => 1,
                   "description" => "how many days ahead",
                   "default" => 3
                 }
               },
               "required" => ["city"],
               "additionalProperties" => false
             }
    end

    test "strict mode makes every property required" do
      schema = openai("get_weather", strict: true)
      assert schema["function"]["parameters"]["required"] == ["city", "days"]
    end

    test "emits an Anthropic tool definition" do
      schema = ToolCall.emit(Weather, :anthropic) |> Enum.find(&(&1["name"] == "add"))
      assert %{"name" => "add", "input_schema" => %{"type" => "object"}} = schema
    end

    test "carries large integers as decimal strings when asked to" do
      schema = openai("big_id")

      assert schema["function"]["parameters"]["properties"]["user_id"] == %{
               "type" => "string",
               "pattern" => "^-?\\d+$",
               "description" => "Snowflake id"
             }
    end
  end

  describe "runtime dispatch" do
    test "applies defaults for omitted trailing arguments" do
      assert {:ok, %{days: 3}} = ToolCall.run(Weather, :get_weather, %{"city" => "Oslo"})
    end

    test "passes explicit arguments through" do
      assert {:ok, %{days: 7}} =
               ToolCall.run(Weather, :get_weather, %{"city" => "Oslo", "days" => 7})
    end

    test "rejects missing required arguments" do
      assert {:error, {:missing_argument, "city"}} = ToolCall.run(Weather, :get_weather, %{})
    end

    test "rejects unknown arguments" do
      assert {:error, {:unknown_arguments, ["nope"]}} =
               ToolCall.run(Weather, :add, %{"a" => 1, "b" => 2, "nope" => true})
    end

    test "rejects unknown tools" do
      assert {:error, {:unknown_tool, "nope", _}} = ToolCall.run(Weather, :nope, %{})
    end

    test "coerces integral floats to integers and rejects fractional ones" do
      assert {:ok, 3} = ToolCall.run(Weather, :add, %{"a" => 1.0, "b" => 2})
      assert {:error, _} = ToolCall.run(Weather, :add, %{"a" => 1.5, "b" => 2})
    end

    test "coerces integers to floats" do
      assert {:ok, 2.0} = ToolCall.run(Weather, :set_temp, %{"value" => 2})
    end

    test "maps enum strings back to atoms" do
      assert {:ok, :ok} = ToolCall.run(Weather, :paint, %{"color" => "red"})
      assert {:error, _} = ToolCall.run(Weather, :paint, %{"color" => "blue"})
    end

    test "parses large integers carried as strings" do
      big = Integer.pow(2, 70)

      assert {:ok, decoded} =
               ToolCall.run(Weather, :big_id, %{"user_id" => Integer.to_string(big)})

      assert decoded == Integer.to_string(big)
    end

    test "turns raised exceptions into tool errors" do
      assert {:error, {:raised, "kaboom"}} = ToolCall.run(Weather, :boom, %{"x" => 1})
    end
  end

  defp openai(name, opts \\ []) do
    ToolCall.emit(Weather, :openai, opts) |> Enum.find(&(&1["function"]["name"] == name))
  end
end
