defmodule ToolCall.Call do
  @moduledoc """
  A resolved tool call, ready for `ToolCall.Runner.execute/2`.

  `ToolCall.Runner.resolve/4` performs the key checks, coercion and positional
  argument construction without invoking the function. The call keeps the raw
  `args` (for approval or display), the coerced `values`, the `positional`
  argument list and the effective `timeout`.

  `execute/2` accepts a `:timeout` override and a `:task_supervisor`; the
  default timeout is the one stored in the call. It also checks the stored
  approval policy unless `:approval` overrides it.
  """

  alias ToolCall.IR.Tool

  @enforce_keys [:module, :tool, :args, :values, :positional]
  defstruct [
    :module,
    :tool,
    :args,
    :values,
    :positional,
    timeout: :infinity,
    approval: nil,
    validate_result?: false
  ]

  @type t :: %__MODULE__{
          module: module(),
          tool: Tool.t(),
          args: map(),
          values: %{optional(String.t()) => term()},
          positional: [term()],
          timeout: :infinity | non_neg_integer(),
          approval: nil | :granted | :denied | module(),
          validate_result?: boolean()
        }
end
