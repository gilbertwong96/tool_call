defmodule ToolCall.Emit.MCP do
  @moduledoc """
  MCP `tools/list` tool object (`name` / `description` / `inputSchema`).

  `inputSchema` is plain JSON Schema. MCP has no `strict` flag, but
  `strict: true` still renders the closed subset — every property required,
  every object closed, optional values nullable — which is valid JSON Schema
  and accepted by MCP clients. See the target matrix in
  [`docs/projection.md`](projection.html).
  """

  alias ToolCall.Emit.Schema
  alias ToolCall.IR.Tool

  @spec emit(Tool.t(), keyword()) :: map()
  def emit(%Tool{} = tool, opts \\ []) do
    reject_fine_tuned!(opts)

    %{
      "name" => tool.name,
      "description" => tool.description || tool.name,
      "inputSchema" => Schema.params(tool, opts)
    }
  end

  defp reject_fine_tuned!(opts) do
    if Keyword.get(opts, :strict) == :fine_tuned do
      raise ArgumentError,
            "the fine-tuned strict mode is OpenAI-only; MCP has no fine-tuned subset"
    end
  end
end
