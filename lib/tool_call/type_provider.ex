defmodule ToolCall.TypeProvider do
  @moduledoc """
  Resolves custom remote typespecs for `use ToolCall, types: [...]`.

  A provider is asked for every remote type that is not built in
  (`t:String.t/0`, `t:Keyword.t/0`, `t:Path.t/0` and the calendar types). It receives
  the remote module, the type name and the already-resolved argument types.

  Return `{:ok, %ToolCall.IR.Type{}}` to describe the value, or `:error` to let
  the type fall back to `{}`. A returned node is validated recursively at
  compile time: unknown kinds, non-string or uncompilable patterns, malformed
  transforms, enum values, bounds, bound ordering, array minimums, formats,
  nullability, field metadata, and malformed
  `fields`/`items`/`variants`/`additional` raise an `ArgumentError` naming the
  provider and the remote type.

  Implement `coerce/1` to convert the wire-coerced value into the function's
  value domain; it runs after the built-in coercion. It is not called for an
  absent optional value, nor for `nil` accepted by a nullable type. An explicit
  `null` for a non-nullable optional value is absent. A raised, thrown or exited
  exception becomes
  `{:error, {:invalid_transform, ...}}` like any other coercion failure. It is a
  shorthand for a provider that resolves one type: a provider that handles
  several types can return `%ToolCall.IR.Type{transform: {Module, :fun}}`
  instead and leave `coerce/1` undefined.
  """

  @callback resolve(module(), atom(), [ToolCall.IR.Type.t()]) ::
              {:ok, ToolCall.IR.Type.t()} | :error

  @callback coerce(term()) :: {:ok, term()} | {:error, term()}

  @optional_callbacks coerce: 1
end
