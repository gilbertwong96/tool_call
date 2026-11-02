defmodule ToolCall.Emit.Anthropic do
  @moduledoc """
  Anthropic tool definition (`name` / `description` / `input_schema`).

  Anthropic returns `tool_use.input` already decoded, so it is subject to the
  provider's own JSON parser. Prefer `wire: :string_integer` for large integers; see
  `docs/number-handling.md`.
  """

  alias ToolCall.Emit.Schema
  alias ToolCall.IR.Tool

  @spec emit(Tool.t(), keyword()) :: map()
  def emit(%Tool{} = tool, opts \\ []) do
    %{
      "name" => tool.name,
      "description" => tool.description || tool.name,
      "input_schema" => Schema.params(tool, Keyword.drop(opts, [:strict]))
    }
  end
end
