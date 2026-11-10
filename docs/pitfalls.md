# Pitfalls

Compile-time traps that are easy to miss when deriving tools from `@spec` and
`@doc`. Release behaviour is covered in [`design.md`](design.md); the type subset and runtime
boundaries are covered in [`design.md`](design.md) and
[`number-handling.md`](number-handling.md).

## `@spec` carries no parameter names

`@spec f(String.t())` is a value domain, not a record. The schema needs property
names, so the library requires annotated arguments:

```elixir
@spec get_weather(city :: String.t()) :: ...
```

The quoted AST for that argument is `{:"::", _, [{:city, _, nil}, type]}`, so the
name survives compilation. An unannotated argument can also take a name from a
`@doc` parameter bullet; otherwise it falls back to the head variable, then
`argN`, with a compile-time warning.

## `@spec` is an accumulative attribute

`Module.get_attribute(mod, :spec)` contains specs for earlier functions too:

```elixir
@spec get_weather(String.t()) :: ...
@spec two_specs(integer()) :: ...
```

The library filters by `{name, arity}` and warns when a function has several
specs; overloads cannot be represented as one JSON Schema.

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

## A `@doc` bullet that names no parameter is dropped

A bullet under `## Parameters` is matched to a parameter by name, or by position
when the spec does not name it. A name that matches nothing — a typo, or a
bullet for an option the function does not take — is dropped, and the compile
warns with the offending name, so a description that does not appear is visible
rather than silent. `## Options` is the exception: it documents the keys of a
keyword argument, so its bullets are not checked against parameter names, do not
name an unannotated parameter by position, and do not warn. The section is not
part of the tool description either — put the keys in the description or flatten
them into parameters if the model must see them.

## `@typedoc` is consumed before `@before_compile`

`@typedoc` is consumed by the following `@type` before `@before_compile` runs,
so the phase-one IR cannot see it. ToolCall recovers docs-visible `@type` and
`@opaque` text in `@after_compile` from the just-compiled `Docs` chunk and
stores the enriched literals in a companion module. It is only a fallback
parameter description: a `@doc` `## Parameters` bullet or a `@tool_param`
description wins. Local alias chains are followed to the nearest documented
type, resolving current-module references inside alias bodies; nested uses such
as `list(address())` do not inherit the typedoc.

`@typep` is different: Elixir discards its typedoc at definition time, so no
docs entry exists to recover. A private type is still resolved for the schema,
but it never contributes a description.

## Stale typedoc companions are inert and cleaned by a compile or task

The companion beam is not registered in Mix's compile manifest. Source-file
companions carry a `.source` sidecar with their source path; every ToolCall
compile prunes companions whose source file is gone. If no ToolCall module
compiles after deleting a source file, or a module was removed from an existing
file, run `mix tool_call.clean` before assembling a release. The task also
scans companion beams directly, using the parent beam and a live source from
either the `.source` sidecar or the beam's `compile_info.source`; a stripped
`compile_info` leaves only the parent-beam check.

The compile-generation token makes any remaining stale companion unusable by
the new module, so it falls back to phase-one data instead of serving stale
descriptions. A companion generated by a ToolCall build that predates the
`__tool_call_companion__/0` marker is treated as foreign, so upgrade with one
`mix clean` or ToolCall warns and skips typedoc enrichment rather than
overwriting it.

## A missing `Docs` chunk is not always a problem

`docs: false` intentionally omits the chunk. ToolCall skips typedoc silently in
that compile and only warns about a missing chunk when docs are enabled. An
undecodable or structurally invalid `Docs` chunk is reported as corrupt and
falls back to phase-one descriptions.

## `@on_definition` accumulates

Unlike `@doc`, `@on_definition` is an accumulating attribute. A `use ToolCall`
does not replace another library's definition hook; both callbacks fire,
including for generated functions such as `__tools__/0`.

## `@enforce_keys` is not readable for a compiled module

`Module.get_attribute(Mod, :enforce_keys)` raises once the module is compiled;
`__info__(:attributes)` returns only `vsn`, and the docs chunk has no entry.
The only observable signal is `ArgumentError` from `__struct__/1` when a key is
missing. The build therefore probes by removing one field at a time, which
costs `n` raised exceptions per struct, once per compile. It does not parse the
message, so a reworded error cannot change the result. A struct is not
recompiled just because a tool module that consumes it changed, but the reverse
holds: `Code.ensure_compiled/1` gives the tool module a compile dependency on
the struct module, so editing `@type t` recompiles the tool.

## A struct's field types come from its public `@type t`

Field names always come from `__struct__/0`, but field types do not. Without a
public `@type t/0` (or for a field it omits) a field is `{}`. A field typed with
the struct module's own `@typep` also stays `{}`, because private types are not
in the types chunk.

A struct whose only type is `@type t/N` (no `t/0`), or whose `t/0` is not a
`%__MODULE__{}` literal (a `| nil` branch is allowed and unwrapped), warns at
compile time: extraction reads `t/0` alone, so the shape you wrote is not being
used. The fields still appear, typed `{}`. Only `@opaque t` leaves the *argument*
untyped, and that hides the tool; see the next entry.

`@opaque t` is deliberately not extracted: the author hid the shape. Note that
most standard-library structs are **not** opaque. `MapSet.t/0` and `Regex.t/0`
are public types whose fields are internal representation, which is why they
have built-in providers (a set travels as an array, a regex as its source
string). `URI.t/0`, `Range.t/0` and `Version.t/0` are extracted, because their
fields are the documented representation.

## A tool with an untyped argument is not exposed

A parameter whose type has no JSON type — `term()`, `any()`, a remote type with
no provider, or an `@opaque` struct — cannot be described, so the function is
skipped the way `@doc false` skips it, and the compile warns with the parameter
name. The function is absent from `tools/1`, `emit/3` and `describe/2`, and
`run/3` answers `{:unknown_tool, name, exposed_names}`. Narrow the argument, add
a `TypeProvider`, or hide the function with `@doc false`. An untyped *field*
inside an object, array or tuple is different: it renders as `{}` and keeps the
tool. Runtime IR (`ToolCall.IR.Tool`) may still carry `:any`; the skip is a
compile-time decision.

## A typedoc companion needs Mix at compile time

`@typedoc` fallback descriptions are persisted next to the compiled beam through
`Mix.Project.compile_path/0`. Compiling outside a Mix project (plain `elixirc`,
an `elixir` script) succeeds, but the companion is skipped with a warning and
the phase-one descriptions are used. Everything else — including `$defs` and
struct extraction — is compile-time and works without Mix.

## A runtime-compiled struct has no readable `@type t`

`Structs` reads `t/0` from the module's typespec chunk, which exists only in a
beam compiled with debug info. A struct module compiled by
`Code.compile_string/1` — a Livebook cell, an eval — has no object code, and a
module compiled with `@compile {:debug_info, false}` has no typespec chunk; in
both cases `Code.Typespec.fetch_types/1` answers `:error`: every field silently
becomes `{}`, and the only signal is the generic "no JSON type" warning on the
parameter. A struct defined in the same module as its tools is exempt (the field
map and `t/0` are read from module attributes). Compile the struct through Mix
or `Kernel.ParallelCompiler.compile_to_path/2` when field types matter.

## Struct defaults are not sent to the model

A `defstruct` default is not emitted as `default` in the schema: the model sees
an optional field and only learns the value if the description says so. Dispatch
applies the default when the field is omitted, because `struct/2` starts from
the struct's defaults. A default does not make an enforced key optional; those
stay in `required`.

## Struct fields have no descriptions

A typespec has no per-field doc, so extraction cannot fill `description` on a
struct's properties: the model sees `city`, `country`, `street` as bare names.
`@doc` and `@typedoc` describe parameters, not fields. Flatten the shape into
parameters with `@doc` bullets, or explain the fields in the tool description,
when their meaning matters.

## A struct and its tools in one module

A struct defined in the same module as its tools gets its field names from the
map that `defstruct` puts in the generated `__struct__/0`, captured at
definition time; `t/0` supplies the field types. A field that `t/0` omits still
appears, typed `{}`. `__struct__/0,1` are not treated as tools. `@opaque t` still
hides the tool, and a module with no generated `__struct__/0` (a hand-written
struct) falls back to `t/0` alone.

`use ToolCall` must come **before** `defstruct` for that capture to happen. If
the struct is declared first, only `t/0`'s fields are used; with no `t/0` there is
no field list at all, and the tool is not exposed.

## A struct type is a shape break in 0.2

`Decimal.t()`, `URI.t()`, `Range.t()` and any other module with a public
`@type t :: %__MODULE__{...}` used to reach the model as `{}` and accept any
value. In 0.2 it is a closed object, and dispatch rebuilds the struct. A
payload that previously passed may now be rejected. Declare a provider for such
an argument if the scalar form was intended. `MapSet` and `Regex` already have a
built-in provider, and a user provider cannot replace it — the built-ins are
tried first. For those two, declare the parameter as `String.t()` or `list(t)`
and convert in the function.

## A struct type with arguments keeps the struct, not the field types

`Mod.t(integer())` is resolved like `Mod.t()` when `Mod` is a struct: dispatch
still rebuilds the struct and result validation still requires one, but the type
arguments are not substituted. Field extraction reads `t/0`, so a struct that
declares only `@type t/N` gives every field `{}` and the compile warns. Declare a
non-parametric `@type t`, or accept `{}` fields for that parameter.

## `@type t :: %__MODULE__{} | nil` is nullable

Field extraction unwraps a nil branch of `t/0`, so the fields keep their types and
`Mod.t()` is nullable wherever it is used: the parameter schema accepts null and
result validation accepts nil. A union with any other type — `%__MODULE__{} |
:error`, say — is still non-literal: every field becomes `{}`, the other branch
is ignored, and the compile warns.

## A schema is per tool, so a shared recursive type is sent once per tool

`describe/2` returns one parameters object per tool, so `$defs` sits per tool
rather than per module. Two tools that share a recursive type each carry an
identical `$defs` block, and a request with N such tools sends N copies; a
non-recursive struct is inlined into every parameter that names it, which also
grows the beam per tool. Both are deliberate (a tool must be self-contained),
but they are prompt-token and compile-size costs worth knowing when one type is
shared widely.

## A ref-only alias cycle fails the compile

`@type a :: b()` with `@type b :: a()` (or an alias that reaches itself through
a union with no constructor) raises `invalid ToolCall IR: $defs cycle ...` at
compile time. A cycle that consumes a value — a ref under an object, array or
tuple, as in `@type tree :: %{children: [tree()]}` — is fine and terminates at
dispatch because the value is finite.

## A hand-built `:ref` needs its `$defs` entry

`ToolCall.IR.Tool.defs` must hold every name a `:ref` points at.
`ToolCall.Typespec.validate_tool!/1` rejects a dangling ref, and
`ToolCall.Coerce` raises `ArgumentError` if it is given one anyway. A ref chain
that never crosses an object, array or tuple is capped at 64 hops and then
raises the same `$ref chain` error from both `Coerce.coerce/4` and
`Coerce.accepts_nil?/2`, so an unvalidated non-productive cycle fails loudly
instead of hanging. A productive cycle resets the count when it consumes a
value, so a 200-level tree is unaffected. Call `validate_tool!/1` on runtime IR
before dispatching it. The `:struct` kind is an internal build marker and is not
accepted from a hand-built tool.

## An exception struct exposes its payload, not `__exception__`

`ArgumentError.t()` and friends extract their payload fields (`message`, plus
any custom field) but not `__exception__`: that sentinel is left at its default
`true`, so dispatch builds a usable exception and `Exception.message/1` works.
An exception type as a tool argument is still unusual; declare a provider if the
exception should travel as a scalar.

## `$defs` names are derived, so treat them as opaque

Names are a pure function of the type and its instantiation: `tree` for a
zero-argument type, `tree_integer_40ca` for a parameterized one, where the suffix
is a signature of the instantiation. They do not depend on any other parameter,
so adding one cannot rename an existing entry, and two compiles of the same
source produce the same names. They are still not a public API: do not depend on
a particular name in a stored schema. Store schemas, not names. Do not
hand-write a `$ref` either; `ToolCall.Typespec.validate_tool!/1` rejects a
dangling entry.

## A recursive parameter pays for the nested key check

The generated generic runner walks a recursive value to report
`{:non_string_arguments, keys}` instead of a plain coercion error. That walk is
the bulk of the roughly 3 µs `run/3` cost for a recursive parameter, against
about 0.17 µs on the scalar fast path. It is a dispatch cost, not a provider
cost. The 32-definition budget is per **tool**, shared by its parameters in
declaration order, so an earlier parameter that grows can push a later one into
`{}`; the 8-instantiation bound is per key within one expansion. Definitions a
struct module contributes are budgeted per struct, not by the tool budget, so a
tool with several struct parameters can exceed 32 entries in total. Depth is
linear, not a cliff: a 100 000-level value coerces in about 0.3 s without
raising.

## Result validation is opt-in and sees the raw return

`ToolCall.run/3` never validates a return value. `run/4` with
`validate_result: true` validates the **raw** value, before `{:ok, value}` /
`{:error, reason}` is unwrapped: a spec `{:ok, map()} | {:error, String.t()}`
returning `{:ok, "not a map"}` fails even though the tool would have answered
`{:ok, "not a map"}` without validation; a spec `map()` whose function returns
`{:ok, %{}}` fails the same way. A mismatch is
`{:error, {:invalid_result, path}}`; a function that raises keeps
`{:error, {:raised, message}}`. A `no_return()` spec has no result type and
skips validation. Validation uses the generic runner path, so it is slower than
the generated fast path.

## A provider type without `validate/3` is accepted

The IR describes a provider type in its **wire** domain (`Date.t()` is a
string), so result validation asks the provider's optional
`validate(type, value, defs)` about the value instead. A provider node with a
`transform` that does not implement it — and does not set
`%ToolCall.IR.Type{validator: {Module, :fun}}` — is accepted unchecked. The
built-ins cover the calendar types, `Keyword` and `MapSet` (both including
element types) and `Regex`; everything else is the provider author's call. A
provider node with neither a transform nor a validator is still checked by its
kind.

## Result validation is strict to the value domain

`float()` rejects an integer, `String.t()` requires valid UTF-8,
`char()` is a codepoint and `charlist()` is a list — while `binary()`,
`bitstring()` and `nonempty_binary()` accept raw bytes without the UTF-8 or
pattern requirement. `nil` is valid on any `nullable: true` node before every
other rule. A closed plain object rejects unknown keys; a struct is checked by
`is_struct/2` plus its declared fields. `keyword(t)` and `MapSet.t(t)` validate
their elements. An improper list or an exotic map key is an
`{:invalid_result, ...}`, not a raise.

## A result type that renders `{}` validates nothing

`Validate.valid?/3` checks a `validator` first, then accepts `:any` and
`:unsupported` before any kind rule. A return type declared as `term()`, an
unknown remote type, `fun()`/`pid()` or a type that hit the definition budget
therefore answers `{:ok, value}` for any value — unless a provider gives the
node a `validator`, which makes it checkable. `no_return()`/`none()` skip
validation entirely. The compile warns for a top-level `:any`/`:unsupported`
result without a validator, for an `@opaque` or unresolved struct, and for a
budget-truncated return type; a validator suppresses the warning because the
value is checked. A nested `{}` inside an object, array or union is still
accepted silently and only that part goes unchecked; narrow the return type when
the whole result must be checked.

## A result struct must satisfy `@type t`, including nil defaults

`defstruct [:city, :country]` gives `country: nil`, while a common `@type t`
declares `country: String.t()`. Result validation enforces the declared type, so
returning `%ToolStruct{city: "Oslo"}` fails with
`{:invalid_result, {"country", {:expected_string, nil}}}` even though the struct
is the one the code builds. `@enforce_keys` does not help: it marks a field
required, it does not make nil valid. Declare `String.t() | nil` for any field
whose default is nil, or set the default.

## A fixed-shape map type is closed, so it rejects a struct

`%{city: String.t()}` builds a closed object. A struct value carries
`__struct__` and its other fields, so a result declared as
`%{city: String.t()}` is rejected with `{:unknown_keys, ["__struct__", ...]}` —
the same rule that rejects an unknown argument key. Declare the struct type
(`Address.t()`) or `map()` when the value may be a struct.

## The result type shares the tool's definition budget

The 32-definition budget is per tool and the parameters consume it first. When
they already use all 32, the result degrades to `{}`/`any` and the compile
warns about the return type, but `run/4` with `validate_result: true` then
accepts any return value. Inspect `tool.result` or the warning when a recursive
result type seems unchecked.

## `atom()` means two different domains

An `atom()` **argument** is checked on the wire: a JSON `true` is a boolean, not
an atom, so it is rejected. An `atom()` **result** is checked in the value
domain, where `true`, `false` and `nil` are atoms and pass. Declare an enum
(`:a | :b`) if both directions must agree.

## `Path.t()` results must be UTF-8

`Path.t()` has no provider transform or validator, so result validation treats
it as a text string: a path with non-UTF-8 bytes (legal on Unix) fails with
`{:invalid_result, {:invalid_utf8, ...}}`. Declare `binary()` if such a path can
be returned.

## `no_return()` results are not validated

A `no_return()` (or `none()`) spec leaves `result: nil`, so `run/4` with
`validate_result: true` accepts whatever the function returns. The same holds
for an aliased `no_return()`. Hide the function with `@doc false` if it must not
be a tool.

## Result-only `$defs` stay out of the input schema

A recursive type referenced only by the return type lives in `Tool.defs` (for
validation) but is filtered out of `inputSchema`/`describe/2`, and it does not
produce "the model will see `{}`" warnings. A type shared by a parameter and the
result is emitted once.

## Remaining design boundaries

Some limits are intentional: nested/remote/provider typedoc inheritance,
`@typep` typedoc recovery, overloaded specs, two arities of one function,
tuple defaults, JSON numbers outside Erlang's finite range, `@doc` metadata-only
entries and type-provider typedoc. See the Design boundaries section in
[`design.md`](design.md).
