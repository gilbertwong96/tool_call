defmodule ToolCall.Emit.Gemini do
  @moduledoc """
  Gemini function declaration (`FunctionDeclaration`).

  Gemini's `parameters` field is a 22-field subset of OpenAPI 3.0, not JSON
  Schema: types are the uppercase `Type` enum, nullability is `nullable: true`,
  and the API rejects every field the subset does not declare. The emitter
  renders the shared schema and then:

    * uppercases `type` and rewrites `type: [T, "null"]` as `nullable: true`;
    * collapses an `anyOf` null branch into `nullable: true`;
    * drops `additionalProperties` (Gemini objects are open);
    * drops `prefixItems` (no positional tuples) and keeps `minItems`/`maxItems`;
    * keeps string enums with `format: "enum"` and drops non-string enums;
    * raises for `$defs`/`$ref`, which `parameters` cannot express.

  The envelope is one declaration: `{"name", "description", "parameters"}`.
  `strict` is ignored because Gemini has no per-tool flag. When
  `additionalProperties` or recursion must be preserved, send
  `parametersJsonSchema` yourself. See the target matrix in
  [`docs/projection.md`](projection.html).
  """

  alias ToolCall.Emit.Schema
  alias ToolCall.IR.Tool

  @spec emit(Tool.t(), keyword()) :: map()
  def emit(%Tool{} = tool, opts \\ []) do
    # The call validates the option shape; Gemini ignores the strict flag.
    params =
      case Schema.strict?(opts) do
        _strict? -> Schema.params(tool, [])
      end

    %{
      "name" => tool.name,
      "description" => tool.description || tool.name,
      "parameters" => ToolCall.Schema.Gemini.to_gemini(params, name: tool.name)
    }
  end
end
