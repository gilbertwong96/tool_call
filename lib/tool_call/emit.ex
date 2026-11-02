defmodule ToolCall.Emit do
  @moduledoc """
  Dispatches IR to a provider-specific schema.

  The IR is intentionally provider-neutral: `docs/design.md` lists the subset
  each provider actually accepts.

  `precompile/1` renders the closed set of provider variants at compile time so
  that a module carries finished schemas as literals; `emit/3` renders loose IR
  values on demand.
  """

  alias ToolCall.IR.Tool

  @type target :: :openai | :anthropic

  @spec emit([Tool.t()] | Tool.t(), target(), keyword()) :: [map()] | map()
  def emit(tools_or_tool, target, opts \\ [])

  def emit(tools, target, opts) when is_list(tools) do
    Enum.map(tools, &emit(&1, target, opts))
  end

  def emit(%Tool{} = tool, :openai, opts), do: ToolCall.Emit.OpenAI.emit(tool, opts)
  def emit(%Tool{} = tool, :anthropic, opts), do: ToolCall.Emit.Anthropic.emit(tool, opts)

  def emit(%Tool{}, target, _opts) do
    raise ArgumentError,
          "unsupported target #{inspect(target)}; expected :openai or :anthropic"
  end

  @doc false
  @spec precompile([Tool.t()]) :: map()
  def precompile(tools) do
    %{
      {:openai, false} => emit(tools, :openai),
      {:openai, true} => emit(tools, :openai, strict: true),
      {:anthropic, false} => emit(tools, :anthropic)
    }
  end

  @doc false
  @spec lookup(map(), target(), keyword()) :: [map()] | map()
  def lookup(schemas, target, opts) do
    strict? = ToolCall.Emit.Schema.strict?(opts) and target == :openai

    case Map.fetch(schemas, {target, strict?}) do
      {:ok, schema} ->
        schema

      :error ->
        raise ArgumentError,
              "unsupported target #{inspect(target)}; available: #{available(schemas)}"
    end
  end

  defp available(schemas) do
    schemas
    |> Map.keys()
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map_join(", ", &inspect/1)
  end
end
