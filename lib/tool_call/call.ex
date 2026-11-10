defmodule ToolCall.Call do
  @moduledoc """
  A resolved tool call, ready for `ToolCall.Runner.execute/2`.

  `ToolCall.Runner.resolve/4` performs the key checks, coercion and positional
  argument construction without invoking the function. The call keeps the raw
  `args` (for approval or display), the coerced `values`, the `positional`
  argument list, the `context`, the effective timeout constant and an optional
  timeout policy. The policy is evaluated by `execute/2`, after approval, with
  the call's raw `args` and context.

  `execute/2` accepts `:timeout`, `:task_supervisor` and `:context` overrides;
  the default timeout, timeout policy and context are the ones stored in the
  call. It also checks the stored approval policy unless `:approval` overrides
  it, and records the dispatch to the stored audit policy unless `:audit`
  overrides it.

  A call is a trusted handoff from `resolve/4`, not data to deserialize from
  model output: `execute/2` invokes the stored `positional` arguments, while an
  approval policy sees the raw `args`.
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
    timeout_policy: nil,
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
          timeout_policy: nil | module(),
          approval: nil | :granted | :denied | module(),
          audit: nil | module(),
          validate_result?: boolean()
        }
end
