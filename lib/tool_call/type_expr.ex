defmodule ToolCall.TypeExpr do
  @moduledoc """
  Source-neutral, unresolved type expressions for `ToolCall.TypeCompiler`.

  A `TypeExpr` describes type shape, local references, remote/provider
  boundaries, and value-domain annotations. It deliberately does not carry
  `ToolCall.IR.Type` wire metadata such as transforms, validators, or JSON Schema
  refs; `TypeCompiler` resolves those later.
  """

  @type field :: {atom(), t(), boolean()}

  @type t ::
          :any
          | :none
          | {:literal, term()}
          | {:primitive, :boolean | :integer | :float | :number | :string | :atom}
          | {:integer_range, integer(), integer()}
          | {:string, map()}
          | {:list, t()}
          | {:nonempty_list, t()}
          | {:tuple, [t()] | nil}
          | {:map, [field()], t() | nil}
          | {:union, [t()]}
          | {:intersection, [t()]}
          | {:negation, t()}
          | {:ref, String.t()}
          | {:ref, {atom(), non_neg_integer()}, [t()]}
          | {:remote, module(), atom(), [t()]}
          | {:builtin, atom(), [t()]}
          | {:dynamic, t()}
          | {:unsupported, term()}
          | {:annotated, t(), map()}

  @doc "The empty type."
  @spec none() :: :none
  def none, do: :none
end
