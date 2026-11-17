defmodule ToolCall.TypeSource do
  @moduledoc """
  Internal contract for function-declaration sources.

  A source loads its compile-time state once, then returns a `Declaration` for a
  function name and arity. the builder consumes the declaration; wire
  emitters never see a source-specific AST.
  """

  defmodule Param do
    @moduledoc "One parameter in a `ToolCall.TypeSource.Declaration`."

    defstruct [:name, :type, named?: false]

    @type t :: %__MODULE__{
            name: atom() | nil,
            type: term(),
            named?: boolean()
          }
  end

  defmodule Declaration do
    @moduledoc """
    A source-neutral function declaration consumed by the builder.

    `source` is compile-time provenance and is dropped from embedded tools.
    `source_label` is used in diagnostics so a future signature source does not
    have to mention `@spec`. `warnings` carries non-fatal source diagnostics.
    """

    defstruct [
      :name,
      :arity,
      :params,
      :return,
      :bindings,
      :source,
      source_label: "the type declaration",
      indirect?: false,
      warnings: []
    ]

    @type t :: %__MODULE__{
            name: atom(),
            arity: non_neg_integer(),
            params: [Param.t()],
            return: term(),
            bindings: %{atom() => term()},
            source: term(),
            source_label: String.t(),
            indirect?: boolean(),
            warnings: [ToolCall.Diagnostic.t()]
          }
  end

  @type state :: term()

  @callback load(module(), Macro.Env.t()) :: state()

  @callback fetch(state(), atom(), non_neg_integer()) ::
              {:ok, Declaration.t()} | {:error, [ToolCall.Diagnostic.t()]}
end
