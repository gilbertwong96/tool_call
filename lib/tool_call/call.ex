defmodule ToolCall.Call do
  @moduledoc """
  A resolved tool call, ready for `ToolCall.Runner.execute/2`.

  `ToolCall.Runner.resolve/4` performs the key checks, coercion and positional
  argument construction without invoking the function. The call keeps the raw
  `args` (for approval or display), the coerced `values`, the `positional`
  argument list, the `context` and the effective `timeout`. The module's timeout
  default or policy is evaluated by `resolve/4` after argument validation.

  `execute/2` accepts `:timeout`, `:task_supervisor` and `:context` overrides;
  the default timeout and context are the ones stored in the call. It also
  checks the stored approval policy unless `:approval` overrides it, and records
  the dispatch to the stored audit policy unless `:audit` overrides it.
  """

  alias ToolCall.IR.Tool

  @enforce_keys [:module, :tool, :args, :values, :positional]
  defstruct [
    :module,
    :tool,
    :args,
    :values,
    :positional,
    :context,
    timeout: :infinity,
    approval: nil,
    audit: nil,
    validate_result?: false
  ]

  @type t :: %__MODULE__{
          module: module(),
          tool: Tool.t(),
          args: map(),
          values: %{optional(String.t()) => term()},
          positional: [term()],
          context: term(),
          timeout: :infinity | non_neg_integer(),
          approval: nil | :granted | :denied | module(),
          audit: nil | module(),
          validate_result?: boolean()
        }
end
