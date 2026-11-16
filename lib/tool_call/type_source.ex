defmodule ToolCall.TypeSource do
  @moduledoc false

  defmodule Param do
    @moduledoc false

    defstruct [:name, :type, named?: false]

    @type t :: %__MODULE__{
            name: atom() | nil,
            type: term(),
            named?: boolean()
          }
  end

  defmodule Declaration do
    @moduledoc false

    defstruct [
      :name,
      :arity,
      :params,
      :return,
      :bindings,
      :source,
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
            indirect?: boolean(),
            warnings: [String.t()]
          }
  end

  @type state :: term()

  @callback load(module(), Macro.Env.t()) :: state()

  @callback fetch(state(), atom(), non_neg_integer()) ::
              {:ok, Declaration.t()} | {:error, [String.t()]}
end
