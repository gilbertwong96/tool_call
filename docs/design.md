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

These were measured on Elixir 1.20.4 / OTP 29. Reproduce with the snippets in
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

Therefore everything is derived in `@before_compile` from module attributes.
Nothing reads the beam back at runtime.

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

Not handled: type variables (generics), recursive types (no `$ref`/`$defs`, so a
recursive reference becomes `{}`), bitstrings with explicit sizes, struct
expansion (without a provider, remote types such as `URI.t()` stay `{}`; the
compiler's inline map form is only reachable once remote expansion exists, and it
carries `__struct__`).

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
quoted AST) but the parameter stays optional. A reduced-arity call receives
every required argument plus a prefix of the optional arguments, which is what
`ToolCall.Runner` constructs.

**Schemas are precompiled, the IR stays the single source.** `@before_compile`
renders the closed set of provider variants and embeds them as literals, so
`emit/3` on a module is a lookup and `strict` can stay a runtime boolean.
Measured on a 20-tool module: a fresh render costs 47 µs per call, the lookup
0.2 µs; the embedded schemas add about 35 KB to the beam and 9 ms to
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
| 0.1 (current) | compile-time derivation, local `@type` resolution, custom type providers, OpenAI (strict included) + Anthropic emitters, coercion, dispatcher |
| 0.2 | `@typedoc` capture via `@after_compile`, `$ref`/`$defs` for recursive types, struct field extraction with `@enforce_keys` |
| 0.3 | result encoding (the return type comes back into the IR), Gemini + MCP `emit/3` targets (MCP export exists), streaming `tool_calls` delta aggregation helpers |
| 0.4 | approval/human-in-the-loop hooks, per-tool timeouts, audit log |
