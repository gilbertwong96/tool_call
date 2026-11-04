# Pitfalls

Compile-time traps that are easy to miss when deriving tools from `@spec` and
`@doc`. Release behaviour is covered in the README; the type subset and runtime
boundaries are covered in [`design.md`](design.md) and
[`number-handling.md`](number-handling.md).

## `@spec` carries no parameter names

`@spec f(String.t())` is a value domain, not a record. The schema needs property
names, so the library requires annotated arguments:

```elixir
@spec get_weather(city :: String.t()) :: ...
```

The quoted AST for that argument is `{:"::", _, [{:city, _, nil}, type]}`, so the
name survives compilation. Unannotated arguments fall back to `arg1`, `arg2`,
… and produce a compile-time warning.

## `@spec` is an accumulative attribute

`Module.get_attribute(mod, :spec)` contains specs for earlier functions too:

```elixir
@spec get_weather(String.t()) :: ...
@spec two_specs(integer()) :: ...
```

The library filters by `{name, arity}` and warns when a function has several
specs; overloads cannot be represented as one JSON Schema.

## Aliases are not expanded in the attribute

An alias such as `Money.t()` arrives as an alias AST. It must be expanded
against the module environment before it can be mapped to a type provider.

## `@typedoc` is consumed before `@before_compile`

`@typedoc` is consumed by the following `@type`; it is gone by the time
`@before_compile` runs. Type-level docs cannot currently be captured. Use
`@doc` parameter bullets or `@tool_param` descriptions instead.

## `@doc` is single-valued and consumed immediately

`@doc` is not an accumulating attribute. Reading it later can attach the last
function's text to every tool, or return `nil`. The library captures it from
`@on_definition`, before the attribute is reset; `@doc false` opts a function
out.

## JSON Schema `integer` accepts `1.0`

Draft 2020-12 defines `integer` as a number with a zero fractional part, so a
decoder can produce `1.0`. `ToolCall.Coerce` truncates integral floats and
rejects fractional ones.

## `float()` parameters can receive integers

`{"type":"number"}` accepts `2`, while `is_float(2)` is false. `ToolCall.Coerce`
widens integers to floats before dispatch.

## JSON numbers Elixir cannot represent

`1e309` is valid JSON but not a finite Erlang float; the decoder raises before
the library sees it. The schema cannot prevent this. See
[`number-handling.md`](number-handling.md).

## `@on_definition` fires for private functions and every clause

The hook sees private helpers and each clause of a multi-clause function. The
library ignores non-`def` callbacks and keeps the first `{name, arity}` entry.

## `@spec` names are documentation, not syntax

The compiler allows duplicate and placeholder parameter names:

```elixir
@spec f(city :: String.t(), city :: integer()) :: String.t()
@spec g(_ :: String.t(), _ :: integer()) :: String.t()
```

The library renames duplicates (`city_2`) and falls back from `_` to the head
variable or `argN`, with a warning. Two arities of one function share a tool
name; only the first is exposed.

## `@doc` metadata never reaches the `:doc` attribute

Metadata-only docs such as `@doc deprecated: "use bar/1"` do not reach the
attribute read by `@on_definition`. They also live in the `Docs` chunk, which a
stripped release removes. A tool declared that way falls back to its function
name; write text as well if the model should see a description.

## `@on_definition` accumulates

Unlike `@doc`, `@on_definition` is an accumulating attribute. A `use ToolCall`
does not replace another library's definition hook; both callbacks fire,
including for generated functions such as `__tools__/0`.
