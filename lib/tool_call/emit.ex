defmodule ToolCall.Emit do
  @moduledoc """
  Dispatches IR to a provider-specific schema.

  The IR is intentionally provider-neutral: `docs/design.md` lists the subset
  each provider actually accepts.

  `precompile/1` renders the closed set of provider-call variants at compile time
  so that a module carries finished schemas as literals; `emit/3` renders loose IR
  values on demand. MCP is not precompiled: its `inputSchema` is the same
  parameters object the other targets embed, so `ToolCall.emit/3` renders it on
  demand. Runtime IR is validated before rendering.
  """

  alias ToolCall.IR.Tool

  @type target :: :openai | :anthropic | :mcp | :gemini

  @spec emit([Tool.t()] | Tool.t(), target(), keyword()) :: [map()] | map()
  def emit(tools_or_tool, target, opts \\ [])

  def emit(tools, target, opts) when is_list(tools) do
    Enum.map(tools, &emit(&1, target, opts))
  end

  def emit(%Tool{} = tool, :openai, opts), do: ToolCall.Emit.OpenAI.emit(tool, opts)
  def emit(%Tool{} = tool, :anthropic, opts), do: ToolCall.Emit.Anthropic.emit(tool, opts)
  def emit(%Tool{} = tool, :mcp, opts), do: ToolCall.Emit.MCP.emit(tool, opts)
  def emit(%Tool{} = tool, :gemini, opts), do: ToolCall.Emit.Gemini.emit(tool, opts)

  def emit(%Tool{}, target, _opts) do
    raise ArgumentError,
          "unsupported target #{inspect(target)}; expected :openai, :anthropic, :mcp or :gemini"
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
              "unsupported target #{inspect(target)}; expected :openai, :anthropic, :mcp or :gemini"
    end
  end
end
