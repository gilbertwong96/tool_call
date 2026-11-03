defmodule ToolCall.Emit do
  @moduledoc """
  Dispatches IR to a provider-specific schema.

  The IR is intentionally provider-neutral: `docs/design.md` lists the subset
  each provider actually accepts.

  `precompile/1` renders the closed set of provider variants at compile time so
  that a module carries finished schemas as literals; `emit/3` renders loose IR
  values on demand. Runtime IR is validated before rendering.
  """

  alias ToolCall.IR.{Param, Tool}

  @type target :: :openai | :anthropic

  @spec emit([Tool.t()] | Tool.t(), target(), keyword()) :: [map()] | map()
  def emit(tools_or_tool, target, opts \\ [])

  def emit(tools, target, opts) when is_list(tools) do
    Enum.map(tools, &emit(&1, target, opts))
  end

  def emit(%Tool{} = tool, :openai, opts) do
    validate_tool!(tool)
    ToolCall.Emit.OpenAI.emit(tool, opts)
  end

  def emit(%Tool{} = tool, :anthropic, opts) do
    validate_tool!(tool)
    ToolCall.Emit.Anthropic.emit(tool, opts)
  end

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

  defp validate_tool!(%Tool{name: name, params: params}) when is_binary(name) do
    Enum.each(params || [], &validate_param!/1)
  end

  defp validate_tool!(%Tool{} = tool) do
    raise ArgumentError,
          "invalid ToolCall IR: tool name must be a string, got: #{inspect(tool.name)}"
  end

  defp validate_param!(%Param{name: name, type: type, wire: wire, required: required})
       when is_binary(name) and wire in [:number, :string_integer] and is_boolean(required) do
    ToolCall.Typespec.validate_type!(type)
  end

  defp validate_param!(other) do
    raise ArgumentError, "invalid ToolCall IR: invalid parameter #{inspect(other)}"
  end
end
