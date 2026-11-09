defmodule ToolCall.GoldenSchemaTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  @golden Path.expand("fixtures/golden_schema.json", __DIR__)

  @source """
  defmodule FIXTURE do
    use ToolCall

    @type status :: :idle | :busy
    @type coords :: %{lat: float(), lon: float()}

    @doc "Exercise every non-recursive mapping."
    @spec go(
            a :: integer(),
            b :: pos_integer() | nil,
            c :: String.t(),
            d :: status(),
            e :: [coords()],
            f :: map(),
            g :: %{optional(String.t()) => integer()},
            h :: {integer(), String.t()},
            i :: keyword(integer()),
            j :: Date.t(),
            k :: float()
          ) :: :ok
    def go(_a, _b, _c, _d, _e, _f, _g, _h, _i, _j, _k), do: :ok
  end
  """

  test "non-recursive schemas are unchanged" do
    module = compile!(@source)

    rendered = %{
      "openai" => ToolCall.emit(module, :openai),
      "openai_strict" => ToolCall.emit(module, :openai, strict: true),
      "anthropic" => ToolCall.emit(module, :anthropic)
    }

    if System.get_env("GOLDEN") == "update" do
      File.mkdir_p!(Path.dirname(@golden))
      File.write!(@golden, JSON.encode!(rendered))
    end

    assert rendered == @golden |> File.read!() |> JSON.decode!()
  end
end
