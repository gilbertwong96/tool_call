defmodule ToolCall.Emit.OpenAI do
  @moduledoc """
  OpenAI function-calling schema.

  Pass `strict: true` to get the shape required by `"strict": true`: the tool
  object carries `"strict": true`, every property is required, previously
  optional values are typed `["T", "null"]`, and every object is closed with
  `additionalProperties: false`.
  """

  alias ToolCall.Emit.Schema
  alias ToolCall.IR.Tool

  @spec emit(Tool.t(), keyword()) :: map()
  def emit(%Tool{} = tool, opts \\ []) do
    schema = %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.description || tool.name,
        "parameters" => Schema.params(tool, opts)
      }
    }

    if Keyword.get(opts, :strict, false), do: Map.put(schema, "strict", true), else: schema
  end
end
