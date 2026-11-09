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
    `pattern_regex` is its compiled form, required by coercion. Use
    `ToolCall.Typespec.validate_type!/1` to build a validated copy of a
    hand-written type. `source` is provenance except for `:charlist`, which
    still drives charlist conversion and its schema default.

    `kind: :ref` names an entry in the tool's `defs` map; emitters render it as
    `{"$ref": "#/$defs/<name>"}` and never resolve it.

    `validator` is the value-domain counterpart of `transform`: a provider type
    describes its wire form in `kind`, and `validator` answers whether a value
    the function returns belongs to the declared type (for example a `%Date{}`
    for `Date.t()`). Result validation uses it; a nil validator on a node with a
    transform means "not checkable" and is accepted.
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
              validator: nil,
              ref: nil,
              struct: nil,
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
      :ref,
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
            | :ref
            | :struct
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
    @moduledoc """
    A compiled tool, as embedded into the defining module.

    `defs` holds the `$defs` entries the tool's parameters and result reference
    by `kind: :ref`. Only the entries reachable from the parameters are rendered
    into the input schema.

    `result` is the declared `@spec` return type, or nil for a `no_return()`
    spec. Result validation uses it; it is never rendered.
    """
    defstruct name: nil,
              description: nil,
              params: [],
              module: nil,
              fun: nil,
              source: nil,
              defs: %{},
              result: nil

    @type t :: %__MODULE__{}
  end
end
