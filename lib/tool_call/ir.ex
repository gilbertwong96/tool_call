defmodule ToolCall.IR do
  @moduledoc """
  Intermediate representation between Elixir typespecs and wire schemas.

  The IR keeps *value-domain* facts (what the Elixir function can really
  accept) separate from *wire* decisions (how a provider should express it
  in JSON Schema). See `docs/design.md`.
  """

  defmodule Field do
    @moduledoc """
    One entry of an object-shaped type.

    `name` is the wire name (always a string, as JSON objects use). `key` is the
    value-domain key: an atom when the spec declared one, which is what the
    function receives.
    """
    defstruct [:name, :key, :type, :description, required: true]

    @type t :: %__MODULE__{}
  end

  defmodule Type do
    @moduledoc """
    A node in the value-domain tree.

    `kind: :any` means "the library could not determine a domain" — usually an
    unknown remote type. `kind: :unsupported` means "the domain is known but
    JSON cannot express it" (functions, pids, refs). Emitters render both as
    `%{}`; only `:unsupported` triggers a compile-time warning.

    `format` is the JSON Schema format string and `transform` is the
    `{module, function}` that runs after the wire value has been coerced. Both
    are populated by a `ToolCall.TypeProvider`; a hand-built calendar node must
    set them explicitly. `pattern` is the JSON Schema regex string and
    `pattern_regex` is its compiled form, used by coercion when present.
    `source` is provenance except for `:charlist`, which still drives charlist
    conversion and its schema default.
    """
    defstruct kind: :any,
              minimum: nil,
              maximum: nil,
              items: nil,
              fields: nil,
              additional: nil,
              values: nil,
              variants: nil,
              pattern: nil,
              pattern_regex: nil,
              format: nil,
              transform: nil,
              nullable: false,
              source: nil

    @kinds [
      :integer,
      :float,
      :number,
      :string,
      :boolean,
      :atom,
      :array,
      :object,
      :tuple,
      :enum,
      :union,
      :null,
      :any,
      :unsupported
    ]

    @type kind ::
            :integer
            | :float
            | :number
            | :string
            | :boolean
            | :atom
            | :array
            | :object
            | :tuple
            | :enum
            | :union
            | :null
            | :any
            | :unsupported

    @doc false
    @spec kinds() :: [kind()]
    def kinds, do: @kinds

    @type t :: %__MODULE__{}
  end

  defmodule Param do
    @moduledoc "One positional parameter of a tool function."
    defstruct [:name, :type, :description, :default, :source, required: true, wire: :number]

    @type wire :: :number | :string_integer
    @type t :: %__MODULE__{}
  end

  defmodule Tool do
    @moduledoc "A compiled tool, as embedded into the defining module."
    defstruct name: nil, description: nil, params: [], module: nil, fun: nil, source: nil

    @type t :: %__MODULE__{}
  end
end
