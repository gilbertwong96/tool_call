# Design

## Goal

Turn an ordinary Elixir function into something a model can call, using the
typespec and doc that already exist:

```elixir
defmodule MyApp.Tools.Weather do
  use ToolCall

  @doc """
  Get the forecast for a city.

  ## Parameters
    * `city` - city name
    * `days` - how many days ahead
  """
  @spec get_weather(city :: String.t(), days :: pos_integer() | nil) ::
          {:ok, %{temp: float()}} | {:error, String.t()}
  def get_weather(city, days \\ 3)
end
```

Two artefacts come out of that single declaration:

1. a wire schema (`ToolCall.emit/3`), and
2. a dispatcher that validates, coerces and applies (`ToolCall.run/3`).

## Non-goals

- Being an HTTP client. This library produces schemas and runs functions; the
  provider call itself is yours.
- Being an agent framework. No loop, no memory, no planning.
- Being a JSON Schema library. It emits a conservative subset; see below.
- Being a JSON encoder. `emit/3` and `describe/2` return terms and your provider
  client encodes the request body. `mix tool_call.export` formats with OTP's
  `json:format/1` (27.1+, the project floor), which sorts keys and keeps a file
  stable on a given OTP version; the formatter is OTP's, so an upgrade may reflow
  the bytes. The plan is to move to Elixir's `JSON` once it can pretty-print.

## Constraints that shaped the design

These constraints shaped the design; compile-time traps are covered in
[`pitfalls.md`](pitfalls.md).

### 1. `@spec` carries no parameter names

`@spec f(String.t())` is a value domain, not a record. The schema needs property
names, so the library requires annotated arguments:

```elixir
@spec get_weather(city :: String.t()) :: ...
```

The quoted AST for that argument is `{:"::", _, [{:city, _, nil}, type]}`, so the
name survives compilation. Unannotated arguments fall back to `arg1`, `arg2`,
… and produce a compile-time warning — a tool with `arg1` is nearly useless to a
model, but silently degrading is worse than warning.

### 2. Runtime reflection is unavailable in releases

`mix release` with `strip_beams: true` (the default) removes the `Docs` and
`Dbgi` chunks. Measured on a stripped beam:

```
Code.Typespec.fetch_specs(M)  #=> :error
Code.Typespec.fetch_types(M)  #=> :error
Code.fetch_docs(M)            #=> {:error, :chunk_not_found}
```

Therefore phase one derives everything in `@before_compile` from module
attributes. The one piece unavailable at that point is `@typedoc`; phase two
reads it from the `Docs` chunk in `@after_compile`, at compile time, and embeds
the result as literals. No runtime path reads the `Docs` or `Dbgi` chunks or
reflects on the compiled beam; the typedoc companion is ordinary compiled code
loaded on first use.

### 3. Typespecs express more than JSON Schema can

Elixir's `integer()` is arbitrary precision; JSON parsers in other languages are
not. `fun()`, `pid()`, `reference()` have no JSON representation at all. The IR
therefore keeps value-domain facts and wire decisions separate; see
[`number-handling.md`](number-handling.md).

## Pipeline

```
def f(a :: T, b)            @on_definition
      │                          │  {name, head_args, doc, file, line}
      ▼                          ▼
  @spec f(A, B) :: R  ───►  ToolCall.Builder (compile time)
                                 │  alias expansion, default detection
                                 ▼
                          ToolCall.IR.Tool
                                 │
                 ┌───────────────┴───────────────┐
                 ▼                               ▼
      ToolCall.Emit.precompile              ToolCall.Coerce
      (openai / openai+strict /             ToolCall.Runner
       anthropic, as literals)
```

`@on_definition` is used instead of scanning `@spec` alone because only that
callback can pair a definition with its `@doc` (the attribute is single-valued
and is consumed immediately) and with `\\` defaults (which live in the function
head, not in the spec).

## Typedoc fallback descriptions

`@typedoc` describes a local type, not a function. It is used only as a fallback
description for a parameter whose declared type is that local type, directly or
wrapped as `address() | nil`. It does not apply to `list(address())`, map fields,
aliases from another module or provider types, and it never changes the tool
description (`@doc` owns that). Precedence:

1. `@tool_param` description
2. `@doc` `## Parameters` bullet
3. `@typedoc` of the parameter's local type
4. no description

An empty-string `@tool_param` description clears the description and suppresses
the fallback. `@typedoc false` contributes nothing. `@typep` has no entry to
recover: Elixir discards its typedoc at definition time, so the type still
participates in local-type inlining but never provides a description.

`@typedoc` is consumed by the following `@type` before `@before_compile`, so
phase one cannot see it. Phase two (`@after_compile`) reads the just-compiled
EEP-48 `Docs` chunk, matches only `{{:type, name, arity}, ...}` entries, and
applies text to parameters whose typedoc key was recorded after variable
substitution and `__MODULE__` localization but before local-type inlining. A
parameterized local type such as `pair(integer())` matches `pair/1`; a `when`
constraint and `__MODULE__.address()` both match `address/0`.

Phase two distinguishes a missing `Docs` chunk from an undecodable or
structurally invalid one. With docs enabled, a missing chunk warns; a compile
with `docs: false` silently skips the fallback because the absent chunk is
expected. A corrupt chunk warns, removes any stale companion and falls back to
the phase-one descriptions. A structurally invalid but term-decodable chunk is
reported as corrupt, not as absent.

### Companion lifecycle and releases

When a description changed, phase two builds the enriched tools and schemas,
creates `Module.concat(module, "__ToolCall__")`, and writes its beam to
`Mix.Project.compile_path/0` for source-file modules. `Code.compile_string/1`
and IEx (`nofile`) modules keep the companion in memory only. When no typedoc
applies, no companion is created and a stale one is removed.

For a module with at least one effective typedoc key — an undocumented
parameter whose declared type is module-local, built with docs enabled — the
original module's `__tools__/0` and `__schemas__/0` delegate only when the
companion exports a matching compile-generation token. The token changes on
every phase-one compile, so a failed or skipped write, a partially written beam,
or an old companion can never serve stale data; the module falls back to the
phase-one literals. Companion creation/writing failures warn and keep the
phase-one literals rather than raising; `--warnings-as-errors` still treats that
warning as a build failure. A loaded module or existing beam without the
`__tool_call_companion__/0` marker is treated as a user module: it is never
purged, overwritten or deleted, and the build warns and uses phase-one
descriptions. Treat `<Module>.__ToolCall__` as reserved.

The companion beam is not in Mix's compile manifest. `mix clean` removes it;
deleting a source module can leave it in ebin until clean (harmless because of
the generation token, though a release may copy the unused beam). A build that
predates the marker leaves foreign companion beams behind until `mix clean`.
Release assembly copies the companion beam from the application's ebin, so a
`strip_beams: true` release still has the enriched literals; the `Docs` and
`Dbgi` chunks are stripped, but the companion's literal functions are not.

The test suite reproduces the stripped-release shape: it compiles a fixture and
its companion, strips `Docs`/`Dbgi` with `:beam_lib`, loads both from an
isolated code path, and calls `ToolCall.emit/3` and `ToolCall.run/3`. It does
not assemble a full `mix release`.

The full path has a manual, checked-in probe: `test/manual_release_probe.sh`
builds a temporary Mix project with a path dependency on this checkout, runs
`MIX_ENV=prod mix release`, and evaluates the public API from the assembled
release. It is not part of `mix test` or `mix ci`, because assembling a release
inside the suite would be slow and environment-dependent. On Elixir 1.20.5 /
OTP 29 it prints:

```
companion beam: _build/prod/rel/typedoc_probe/lib/typedoc_probe-0.1.0/ebin/Elixir.TypedocProbe.__ToolCall__.beam
description: "Postal address"
run: {:ok, :ok}
docs: {:error, :chunk_not_found}
specs: :error
```

The `docs` and `specs` lines show that the release stripped the chunks, while
the companion beam is present. `emit/3` returns the typedoc description and
`run/3` dispatches through the companion's tools; `run/3` returns the function
result and does not read a description.

## Type mapping

Local `@type`, `@typep` and `@opaque` declarations are inlined before mapping,
including parameterised ones (`@type pair(a) :: {a, a}`), because a named type
declared in the same module is not a distinct domain — it is a name for one.
Recursive definitions cannot be inlined, so the first re-entry stays unresolved
and renders as `{}`.

Inlining is also budgeted. A hierarchy such as `@type t0 :: {t1(), t1()}` where
every level doubles grows as `2^depth`; measured on Elixir 1.20.4, depth 16 took
16 s and depth 18 took 83 s to compile, with no upper bound. After 100
inlinings the rest of the type is left unresolved, renders as `{}` and the
build warns. Depth 18 now compiles in 28 ms.

| Elixir typespec | IR | JSON Schema |
|---|---|---|
| `integer()` | `:integer` | `{"type":"integer"}` |
| `non_neg_integer()` | `:integer` min 0 | `+ "minimum": 0` |
| `pos_integer()` | `:integer` min 1 | `+ "minimum": 1` |
| `neg_integer()` | `:integer` max -1 | `+ "maximum": -1` |
| `byte()` | `:integer` 0..255 | bounds |
| `1..10` | `:integer` 1..10 | bounds |
| `float()` | `:float` | `{"type":"number"}` |
| `number()` | `:number` | `{"type":"number"}` |
| `String.t()`, `binary()`, `bitstring()` | `:string` | `{"type":"string"}` |
| `nonempty_binary()`, `nonempty_string()` | `:string` | `+ "pattern": "^[\\s\\S]+$"` |
| `charlist()` | `:string` | `{"type":"string"}`; the function receives a charlist |
| `char()` | `:string` | `+ "pattern": "^[\\s\\S]$"`, enforced at dispatch; the function receives the codepoint |
| `boolean()` | `:boolean` | `{"type":"boolean"}` |
| `true`, `false` | `:enum` | `{"type":"boolean","enum":[true]}` |
| `atom()`, `module()` | `:atom` | `{"type":"string"}` |
| `:a \| :b` | `:enum` | `{"type":"string","enum":["a","b"]}` |
| `1 \| 2` | `:enum` | `{"enum":[1,2]}` |
| `nil` in a union | `nullable: true` | `{"type":["T","null"]}`; an enum becomes `anyOf` with a null branch |
| `map()` | `:object` open | `"additionalProperties": true` |
| `struct()` | `:object` open | no struct reconstruction; the function receives a map; use a TypeProvider for concrete fields |
| `%{k: t}` | `:object` | required fields; the function receives atom keys |
| `%{optional(k) => t}` | `:object` | not in `required`; atom keys at dispatch |
| `%{k() => t}` | `:object` | `additionalProperties: <t>`; keys stay strings |
| `[t]`, `list(t)` | `:array` | `{"type":"array","items":...}` |
| `nonempty_list(t)` | `:array` | `+ "minItems": 1` |
| `{a, b}`, `{a, b, c}` | `:tuple` | `prefixItems` + min/maxItems; strict keeps only the size; the function receives a tuple |
| `tuple()` | `:tuple`, no fixed items | array with unconstrained items; the function receives a tuple |
| `keyword(t)`, `Keyword.t()` | `:object` | `additionalProperties: <t>`; the function receives a keyword list |
| `Date.t()`, `DateTime.t()`, `Time.t()` | `:string` | `+ "format": "date" / "time" / "date-time"`; parsed from ISO 8601 at dispatch |
| `NaiveDateTime.t()` | `:string` | no `format`: RFC 3339 `date-time` needs an offset; parsed at dispatch |
| `Path.t()` | `:string` | `{"type":"string"}`; already a binary |
| `fun()`, `fun(...)`, `pid()`, `port()`, `reference()`, `mfa()` | `:unsupported` | `{}` + warning |
| `term()`, `any()` | `:any` | `{}` |
| unknown remote type without a provider | `:any` | `{}` |

**Remote types are provider-driven.** `String`, `Keyword`, `Path` and the
calendar types come from the built-in stdlib provider.
`use ToolCall, types: [...]` prepends the built-ins before user providers; a
provider receives the argument types already resolved to IR and returns an IR
node, or `:error` to fall back to `:any`. The returned node is validated
recursively at compile time: unknown kinds, invalid patterns, transforms, enum
values, bounds, bound ordering, array minimums, formats, nullability or field
metadata, and malformed `fields`/`items`/`variants`/`additional` raise. An optional `coerce/1` runs after
the built-in wire coercion. A remote type without a matching provider degrades
to `{}` and warns.

The IR is also public for runtime-built tools. A hand-built calendar node must
set `format`/`transform`; `source` is provenance except for `:charlist`, which
still drives charlist conversion and its schema default. `ToolCall.emit/3`
validates runtime IR before rendering.

Not handled: recursive types (no `$ref`/`$defs`, so a recursive reference
becomes `{}`), bitstrings with explicit sizes, and struct expansion (without a
provider, remote types such as `URI.t()` stay `{}`).

A union of the same kind is collapsed only when the collapse is exact. Integer
bounds are treated as intervals: `0..10 | pos_integer()` is `0..∞`, a contained
range disappears, and ranges with a hole stay `anyOf`. Structural kinds are never
collapsed by kind, because `[integer()] | [String.t()]` is not `[integer()]`.

## Provider subsets

The same IR, three different realities:

| | OpenAI | Anthropic | Gemini / MCP |
|---|---|---|---|
| Shape | `{"type":"function","function":{...}}` | `{name, description, input_schema}` | `inputSchema` |
| Top level | must be an object | any JSON Schema | any JSON Schema |
| `strict: true` | sets the flag, makes every property required, closes every object, warns about parameters that cannot be typed | n/a | n/a |
| `$ref` | limited | accepted but rarely useful | unsupported |
| Who parses arguments | you (a JSON string) | the provider (`input` arrives decoded) | varies |

The last row matters for large integers: when the provider parses, you inherit
its numeric precision. It is the reason `wire: :string_integer` exists.

## Decisions

**Value domain vs wire format.** `@spec` describes what the function accepts.
`@tool_param` describes how it travels. Big integers are still `integer()` in
the spec:

```elixir
@tool_param %{fun: :transfer, name: "user_id", wire: :string_integer,
              description: "Snowflake id"}
@spec transfer(user_id :: integer()) :: String.t()
```

Keeping these orthogonal means the function stays reusable outside of tool
calls.

All string wire values are Unicode. Invalid UTF-8 from a provider or direct
caller is rejected at dispatch as `{:invalid_utf8, value}` rather than raised;
the schema can only say `"type": "string"`, so the runtime boundary is the
enforcement point.

**The value domain is restored at dispatch.** Coercion does not stop at checking
the wire value: `%{a: integer()}` is handed over with atom keys, `keyword(t)` as a
keyword list, `charlist()` as a charlist, `char()` as a codepoint, tuples as
Erlang tuples, `Date.t()` and friends as structs parsed from ISO 8601, and an
integral float as an integer.
One thing stays wire-shaped because JSON has no better form: keys the spec does
not declare (open maps, `%{k() => v}`) keep their string form. `keyword/1` keys are
resolved with `String.to_existing_atom/1`, the same rule as `atom()`: a key that
is not already in the atom table yields `{:unknown_atom, key}` instead of a new
atom per request.

**Optional = has a default.** `required` is derived from `\\`, wherever the
default appears in the argument list. A default that is not a compile-time
literal is dropped from the schema (it would otherwise reach the model as a
quoted AST) but the parameter stays optional. A literal that is valid JSON but
outside the parameter's value domain is also dropped, with a compile-time
warning. A reduced-arity call receives every required argument plus a prefix of
the optional arguments, which is what `ToolCall.Runner` constructs.

**Schemas are precompiled, the IR stays the single source.** `@before_compile`
renders the closed set of provider variants and embeds them as literals, so
`emit/3` on a module returns a precompiled literal and `strict` can stay a
runtime boolean. A module whose effective typedoc key map is empty — no
undocumented parameter whose declared type is a module-local type, or docs are
disabled — gets direct `__schemas__/0` and `__tools__/0` functions that return
those literals. Only a declared type that is a module-local type, directly or
wrapped as `<type>() | nil`, produces a typedoc key; `list(address())` and
`%{address: address()}` stay on the direct path. When at least one such key
exists (with docs enabled), a `@typedoc` companion may exist, so the accessors
check it with `Code.ensure_loaded?/1` and `function_exported?/3` before using
it, which keeps a stale companion from serving old data.

Measured locally on a 20-tool module (Elixir 1.20.5, OTP 29): a module whose
effective typedoc key map is empty reads the literals directly — `emit/3` costs
about 0.07 µs per call, `__schemas__/0` about 13 ns and `run/3` about 0.5 µs.
That includes a module whose local-type parameter is already documented by a
`@doc` bullet or `@tool_param` description. With a typedoc companion present,
`emit/3` costs about 0.14 µs and `run/3` about 0.6 µs. A module with an
undocumented local-type parameter whose type has no visible `@typedoc` still
takes the guarded path and pays roughly 16–26 µs per call because the failed
`Code.ensure_loaded?/1` searches the code path (the exact cost depends on the
code path length); the companion is removed, but the accessor cannot know that
without the lookup. A fresh render of a runtime `ToolCall.IR.Tool` costs about
0.5 µs per call. The embedded schemas add about 35 KB to the beam and 9 ms to
compilation. A module built at runtime (`ToolCall.IR.Tool`) is rendered on
demand instead.

**Strict mode is an emitter concern.** `strict: true` sets the tool flag,
rewrites optional properties to `["T","null"]`, moves every property (nested
objects included) into `required`, and closes every object with
`additionalProperties: false`, because OpenAI rejects the alternative. A
parameter whose domain has no JSON type (`term()`, `map()`, `pid()`) cannot be
expressed in that subset at all, so the emitter warns instead of shipping a
schema the API will reject. The same applies to open objects with typed values
(`keyword(t)`, `%{k() => v}`): closing them leaves an object that accepts no key,
which the build warns about too.

Because strict mode forces `null` onto optional properties, the dispatcher
treats an explicit `null` for a **non-nullable** optional argument or field as
absent. Without that rule the two halves would disagree: the model would be
told to send `days: null` and the dispatcher would answer
`{:expected_integer, nil}`. If the type itself accepts `nil`, explicit `null`
is preserved and can override the default.

Two more keywords have to go in that variant, because the API rejects them:
`default` (dropped; nullability says the same thing) and `prefixItems` (a tuple
keeps its `minItems`/`maxItems` but loses the element types, and the build warns).
`pattern`, numeric bounds and `minItems`/`maxItems` *are* part of the strict
subset, which is why `wire: :string_integer` and `char()` work there.

**Names are normalised at compile time.** `@spec` names are documentation, not
syntax, so the compiler accepts duplicates and `_`. The library renames a
duplicate to `name_2` and falls back from `_` to the head variable or `argN`,
with a warning each time; the alternative is a tool whose `required` list
repeats a name and whose dispatcher can never satisfy both parameters. Two
arities of the same function produce one tool name, so the first is kept and the
second warns. Tool names that the providers reject (`find?`) warn too — the
runtime has no name mapping, so renaming would silently change what the model
calls.

**Type overrides are scoped to a function.** `@tool_param` names the function it
belongs to because two tools may have a `user_id` that means different things:

```elixir
@tool_param %{fun: :transfer, name: "user_id", wire: :string_integer}
@tool_param %{fun: :lookup, name: "user_id", description: "Internal id"}
```

An override that matches no function or no argument warns at compile time — a
silently ignored annotation is worse than a noisy one.

**Validation and coercion are one pass.** The schema says `1.0` is a valid
integer; Elixir disagrees; `ToolCall.Coerce` bridges the gap instead of letting
the function crash.

**Unknown arguments are rejected.** The emitted schema says
`additionalProperties: false`, so the dispatcher enforces the same rule and
returns an error the model can read.

**Arguments that cannot be positioned are an error.** Elixir fills defaults in
declaration order, so `run(f, %{"b" => 2})` on `def f(a \\ 1, b \\ 2)` has no
positional form: a reduced-arity call would bind `2` to `a`, not to `b`.
Returning `{1, 2}` would silently change the call; the dispatcher returns
`{:argument_gap, "a", ["b"]}` instead. A required argument after an omitted
optional one is still fine: `def f(a \\ 1, b)` accepts `%{"b" => 2}`.

## Dispatch errors

`ToolCall.run/3` returns `{:ok, term}` or one of:

| Error | Cause |
|---|---|
| `{:unknown_tool, name, known}` | no tool with that name |
| `{:unknown_arguments, names}` | keys the tool does not declare |
| `{:non_string_arguments, keys}` | `args` used atom or other non-string keys |
| `{:invalid_arguments, args}` | `args` was not a map |
| `{:missing_argument, name}` | a required argument is absent |
| `{:argument_gap, missing, dropped}` | a later optional argument was supplied after an omitted optional one; required arguments may still follow an omitted optional |
| `{:invalid_argument, {name, reason}}` | coercion or bounds failed |
| `{:raised, message}` | the function raised |
| `{:thrown, value}` / `{:exited, reason}` | the function threw or exited |

The reason terms are deliberately plain data: the caller decides how to render
them, and no dependency on a JSON library leaks into the library. A rescued
exception is logged with its stacktrace before it is turned into
`{:raised, message}`; otherwise the trace would be lost, because the dispatcher
never lets it propagate.

## Roadmap

| Stage | Work |
|---|---|
| 0.1 (current) | compile-time derivation, local `@type` resolution, `@typedoc` fallback descriptions, custom type providers, OpenAI (strict included) + Anthropic emitters, coercion, dispatcher |
| 0.2 | `$ref`/`$defs` for recursive types, struct field extraction with `@enforce_keys` |
| 0.3 | result encoding (the return type comes back into the IR), Gemini + MCP `emit/3` targets (MCP export exists), streaming `tool_calls` delta aggregation helpers |
| 0.4 | approval/human-in-the-loop hooks, per-tool timeouts, audit log |
