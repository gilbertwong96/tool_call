defmodule ToolCall.TypeProvider do
  @moduledoc """
  Resolves custom remote typespecs for `use ToolCall, types: [...]`.

  A provider is asked for every remote type that is not built in
  (`t:String.t/0`, `t:Keyword.t/0`, `t:Path.t/0` and the calendar types). It receives
  the remote module, the type name and the already-resolved argument types.

  Return `{:ok, %ToolCall.IR.Type{}}` to describe the value, or `:error` to fall
  back: to `{}`, or to struct field extraction when `Mod` is a concrete struct
  (see the Structs section of `docs/design.md`). A returned node is validated recursively at
  compile time: unknown kinds, non-string or uncompilable patterns, malformed
  transforms, enum values, bounds, bound ordering, array minimums, formats,
  nullability, field metadata, and malformed
  `fields`/`items`/`variants`/`additional` raise an `ArgumentError` naming the
  provider and the remote type.

  Implement `coerce/1` to convert the wire-coerced value into the function's
  value domain; it runs after the built-in coercion. It is not called for an
  absent optional value, nor for `nil` accepted by the nullable shortcut. An
  explicit `null` for a non-nullable optional value is absent. If `nil` is
  accepted by `any()`, an enum containing `nil`, or a union with such a branch,
  it reaches `coerce/1` like any other value. A raised, thrown or exited
  exception becomes
  `{:error, {:invalid_transform, ...}}` like any other coercion failure. It is a
  shorthand for a provider that resolves one type: a provider that handles
  several types can return `%ToolCall.IR.Type{transform: {Module, :fun}}`
  instead and leave `coerce/1` undefined. When both are present, the `coerce/1`
  shorthand replaces the returned `transform`, while an explicit `validator`
  wins over `validate/3`.

  Implement `validate/3` to describe the **value domain** of the types the
  provider resolves: it receives the resolved IR node, the value the tool
  function returns (a `%Date{}`, not an ISO 8601 string) and the tool's `$defs`
  map, and returns a boolean. Result validation (`ToolCall.run/4` with
  `validate_result: true`) uses it instead of the wire kind. Resolve element
  types through `ToolCall.Validate.valid?/3`; the built-ins do this for
  `MapSet` and `Keyword`. A provider node with a `transform` and no `validate/3`
  (and no explicit `%ToolCall.IR.Type{validator: ...}`) is accepted unchecked; a
  node with neither is still checked by its kind.
  """

  @callback resolve(module(), atom(), [ToolCall.IR.Type.t()]) ::
              {:ok, ToolCall.IR.Type.t()} | :error

  @callback coerce(term()) :: {:ok, term()} | {:error, term()}

  @callback validate(ToolCall.IR.Type.t(), term(), %{String.t() => ToolCall.IR.Type.t()}) ::
              boolean()

  @optional_callbacks coerce: 1, validate: 3
end
