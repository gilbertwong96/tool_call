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
          {:ok, map()} | {:error, String.t()}
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

## Design constraints

These constraints shaped the design; compile-time traps are covered in
[`pitfalls.md`](pitfalls.md).

### 1. `@spec` carries no parameter names

`@spec f(String.t())` is a value domain, not a record. The schema needs property
names, so the library requires annotated arguments:

```elixir
@spec get_weather(city :: String.t()) :: ...
```

The quoted AST for that argument is `{:"::", _, [{:city, _, nil}, type]}`, so the
name survives compilation. An unannotated argument can take a name from a
`@doc` parameter bullet; otherwise it falls back to the head variable, then
`argN`, with a compile-time warning — a tool with `arg1` is nearly useless to a
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
                                 │  alias expansion, default detection,
                                 │  local-type inlining, $defs hoisting,
                                 │  struct discovery and resolution
                                 ▼
                        ToolCall.IR.Tool (params, defs)
                                 │
                 ┌───────────────┴───────────────┐
                 ▼                               ▼
      ToolCall.Emit.precompile              ToolCall.Codegen
      (openai / openai+strict /             per-tool dispatch, scalar
       anthropic, as literals;              fast path; Runner fallback
       $ref + $defs)                        threads the tool defs
```

`@on_definition` is used instead of scanning `@spec` alone because only that
callback can pair a definition with its `@doc` (the attribute is single-valued
and is consumed immediately) and with `\\` defaults (which live in the function
head, not in the spec).

## Typedoc fallback descriptions

`@typedoc` describes a local type, not a function. It is used only as a fallback
description for a parameter whose declared type is that local type, directly or
wrapped as `address() | nil`. A local alias chain such as
`@type location :: address()` is followed until a documented type is found; the
nearest key with a typedoc wins. Current-module `__MODULE__` and alias
references inside alias bodies are resolved before traversal. It does not apply
to `list(address())`, map fields, aliases from another module or provider types,
and it never changes the tool description (`@doc` owns that). Precedence:

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
substitution, alias expansion and current-module localization but before
local-type inlining. A parameterized local type such as `pair(integer())`
matches `pair/1`; a `when` constraint and `__MODULE__.address()` both match
`address/0`. The same applies to `MyModule.address()` and to an alias of the
current module, such as `Self.address()`.

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

The companion beam is not in Mix's compile manifest. `mix clean` removes it.
A source-file companion has a `.source` sidecar pointing at its source path;
every ToolCall compile prunes companions whose source file is gone, and
`mix tool_call.clean` performs the same cleanup without a compile. The task also
scans companion beams directly: a missing parent beam removes an owned
companion, and a live source from either the `.source` sidecar or the beam's
`compile_info.source` keeps it. A stripped `compile_info` leaves only the
parent-beam check. A remaining stale beam is harmless because of the generation
token, though a release may copy it. A build that predates the marker leaves
foreign companion beams behind until `mix clean`.
Release assembly copies the companion beam from the application's ebin, so a
`strip_beams: true` release still has the enriched literals; the `Docs` and
`Dbgi` chunks are stripped, but the companion's literal functions are not.

A `ToolCall.TypeProvider` that defines `coerce/1` runs at dispatch time, so the
provider module must be present in the release; do not put it in a
`runtime: false` dependency if the tool uses it. Do not reconstruct tools at
runtime from the compiler's typespec or Docs chunks; use the embedded
`ToolCall.tools/1` IR or construct `ToolCall.IR.Tool` values explicitly.

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
`run/3` uses the generated per-tool dispatch and embedded IR; the typedoc
companion affects descriptions, not dispatch. `run/3` returns the function
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
| `struct()` | `:object` open | the function receives a map; use a concrete struct type for fields |
| `%Mod{}`, `Mod.t()`, `Mod.t(...)` with a public `@type t` | `:object`, `struct: Mod` | closed object; `required` from `@enforce_keys`; a nil branch in `t` makes it nullable; type arguments are not substituted |
| `%Mod{}`, `Mod.t()`, `Mod.t(...)` with `@opaque t` | `:any` | `{}` + warning; the field set is hidden |
| recursive `@type` | `:ref` + `$defs` | one body in `$defs`, a `$ref` at every occurrence |
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
| `MapSet.t()`, `MapSet.t(t)` | `:array` | elements at the wire; dispatch returns a `MapSet` |
| `Regex.t()` | `:string` | the source string, compiled with `u` at dispatch |
| `fun()`, `fun(...)`, `pid()`, `port()`, `reference()`, `mfa()` | `:unsupported` | `{}` + warning |
| `term()`, `any()` | `:any` | `{}` |
| unknown remote type without a provider | `:any` | `{}` |

**Remote types are provider-driven.** `String`, `Keyword`, `Path`, the calendar
types, `MapSet` and `Regex` come from built-in providers.
`use ToolCall, types: [...]` prepends the built-ins before user providers; a
provider receives the argument types already resolved to IR and returns an IR
node, or `:error` to fall back to `:any`. The returned node is validated
recursively at compile time: unknown kinds, invalid patterns, transforms, enum
values, bounds, bound ordering, array minimums, formats, nullability or field
metadata, and malformed `fields`/`items`/`variants`/`additional` raise. An optional `coerce/1` runs after
the built-in wire coercion. A remote type without a matching provider degrades
to `{}` and warns.

The IR is also public for runtime-built tools. A hand-built calendar node must
set `format`/`transform`; `source` is an atom for the string sub-kinds
(`:charlist`, `:char`, `:binary`, `:bitstring`, `:nonempty_binary`,
`:nonempty_string`), which dispatch and result validation read. Any other source
is provenance and is dropped from the embedded IR. `ToolCall.emit/3`
validates runtime IR before rendering.

Not handled: bitstrings with explicit sizes and `@typep` field types inside a
struct (the types chunk exposes public types only). Another module's non-struct
type without a provider leaves the *argument* untyped, and a tool with an untyped
argument is not exposed; the same applies to `term()`, `any()` and `@opaque`
structs. Recursive types and concrete structs are handled; see below.

A union of the same kind is collapsed only when the collapse is exact. Integer
bounds are treated as intervals: `0..10 | pos_integer()` is `0..∞`, a contained
range disappears, and ranges with a hole stay `anyOf`. Structural kinds are never
collapsed by kind, because `[integer()] | [String.t()]` is not `[integer()]`.

### Recursive types

Cyclicity is decided **statically**, once per module, before any type is
converted: build a graph over the module's local `@type`/`@typep`/`@opaque`
definitions (an edge exists when one body mentions another key) and mark every
key that can reach itself. A cyclic key is never inlined. Each instantiation
becomes one `$defs` entry, and every occurrence — including the parameter that
starts the cycle — is `$ref`:

```json
{
  "type": "object",
  "properties": { "root": { "$ref": "#/$defs/tree" } },
  "required": ["root"],
  "additionalProperties": false,
  "$defs": {
    "tree": {
      "type": "object",
      "properties": {
        "value": { "type": "integer" },
        "children": { "type": "array", "items": { "$ref": "#/$defs/tree" } }
      },
      "required": ["children", "value"],
      "additionalProperties": false
    }
  }
}
```

`$defs` sits beside `properties` in the parameters object, per tool. Strict
mode renders each definition with the same rules as a nested object (closed,
every property required, optional values nullable). A nullable ref
(`tree() | nil`) becomes `anyOf` with a null branch, because a `$ref` cannot
carry a sibling `type` array. Non-recursive local types keep the inlining,
budget and warning path described above, so their schemas do not change.

Names are readable and derived from the instantiation: `tree` for a zero-argument
type; a parameterized one renders its arguments by kind and appends a
four-hex-digit signature of the instantiation (`tree_integer_40ca`). Sanitised to
`[A-Za-z0-9_]`, truncated at 64 characters, with `_2`, `_3` on a collision after
truncation. The name is a pure function of `{key, args}` and of nothing else, so
adding a parameter cannot rename an existing entry, and two compiles of the same
source produce the same names. Two bounds keep a pathological parameterized
cycle finite: `@max_defs 32` per tool, shared by its parameters in declaration
order, and `@max_instantiations_per_key 8` (a call that transforms its own
arguments, `@type t(a) :: %{next: t({a, a})}`, grows the argument tree
exponentially). Past either bound the reference degrades to `{}` and the compile
warns. Definitions a struct module contributes are budgeted per struct, not by
the tool budget.

A cyclic value is coerced through the same `$defs` map at dispatch, so nested
maps arrive with atom keys at every level. Coercion is driven by the value,
which is finite, so the type-level cycle terminates.

### Structs

`Mod.t()`, `Mod.t(...)` and `%Mod{}` are resolved for a module that exports
`__struct__/0`, when no `TypeProvider` matches first. Type arguments are not
substituted: a parameterized `@type t/N` with no `t/0` leaves every field `{}`
and warns. The result is a closed object:

- field names come from `__struct__/0`, sorted by name;
- field types come from the module's public `@type t`, with the module's own
  local types expanded and a self-reference to `t/0` replaced by
  `%__MODULE__{}`; a nil branch of `t/0` is unwrapped, so the struct is nullable
  wherever it is used, and a field missing from `t` keeps `{}`;
- `required` comes from `@enforce_keys`.

`@enforce_keys` is not readable for a compiled module: `Module.get_attribute/2`
raises, and neither `__info__(:attributes)` nor the docs chunk carries it. The
only signal is `ArgumentError` from `__struct__/1`, so the build removes one
field at a time and treats a field whose removal raises as enforced. That is
`n` probes per struct, once per compile, with no message parsing.

`@opaque t` is **not** extracted: the author chose to hide the shape. Note that
most standard-library structs are public, not opaque; `MapSet` and `Regex` are
claimed by built-in providers before extraction, because their fields are
internal representation. `URI`, `Range` and `Version` are extracted, because
their fields are the documented representation.
Such a parameter stays `{}` with the untyped warning. A provider always wins,
which is the escape hatch for a scalar wrapper (`Decimal.t()`, `Range.t()`) if
its field shape is not what you want the model to see.

Struct cycles are handled like type cycles: discovery resolves the struct graph
through `@type t`, the strongly connected components decide which modules are
cyclic, and a cyclic module becomes one `$defs` entry with a `$ref` at every
occurrence, including the parameter. `Code.ensure_compiled/1` at compile time
adds the compile dependency, so editing the struct's `@type t` recompiles the
tool module.

At dispatch, an object with `struct: Mod` is coerced field by field and then
rebuilt with `struct/2`. Omitted optional fields are not inserted, so
`defstruct` defaults apply; an unknown key is `{:unknown_keys, keys}`.

## Result validation

The declared `@spec` return type is derived into `%Tool{result: Type.t() | nil}`
through the same pipeline as an argument: `when` variable substitution, alias
expansion, local type inlining with `$defs` hoisting, and struct resolution. It
shares `Tool.defs` and the tool's 32-definition budget. `no_return()` and
`none()` leave `result: nil`.

The input schema is unaffected: `Emit.Schema.params/2` renders only the defs
reachable from the parameters (`ToolCall.Defs.reachable/2`), so a recursive type
used only by the result stays in the IR and out of `inputSchema`, and it does not
produce "the model will see `{}`" warnings.

Validation is **opt-in**:

```elixir
ToolCall.run(MyApp.Tools.Weather, :get_weather, args, validate_result: true)
```

- It runs through the generic `ToolCall.Runner` path, so no generated code
  changes; `run/3` keeps the fast path and never validates.
- It validates the **raw** return value, before `Runner.normalize/1` unwraps
  `{:ok, value}` / `{:error, reason}`. The spec describes what the function
  returns, so `@spec f() :: {:ok, map()} | {:error, String.t()}` returning
  `{:ok, "not a map"}` fails.
- A mismatch returns `{:error, {:invalid_result, reason}}`; `result: nil` skips.
- A function that raises/throws/exits keeps its current error, unvalidated.

`ToolCall.Validate.valid?/3` checks the value domain:

- `nil` on a `nullable: true` node is valid before any other rule.
- A node with `validator: {M, f}` is checked by `f(type, value, defs)`; the
  validator **replaces** the kind rule, because a provider type's kind describes
  its wire form. It receives the resolved node and the tool's `$defs`, so it can
  validate element types (`MapSet`, `Keyword`) through `Validate.valid?/3`.
- A node with a `transform` and no `validator` describes a domain the library
  cannot see, so it is accepted.
- A non-productive `$ref` chain raises after 64 same-level hops, mirroring
  `Coerce`; a productive cycle (a ref under an object/array/tuple) resets and
  terminates on the value.
- A value the library cannot even index — an improper list, or a map key that is
  not an atom or a binary — is reported as `{:invalid_result, ...}`, never a
  raise.
- `binary()`/`bitstring()`/`nonempty_binary()` use their real value domains (no
  UTF-8 or pattern requirement); `String.t()` requires valid UTF-8 and its
  pattern; `char()` is a codepoint and `charlist()` a list.
- `float()` requires a float; `number()` accepts integers and floats.
- Structs check `is_struct/2`, required fields and field types; a closed plain
  object rejects unknown keys; an open object accepts them.
- Arrays and tuples check length and elements with index paths; unions accept any
  matching variant; `:ref` resolves through `defs`.

`ToolCall.TypeProvider` gains an optional `validate/3`:
`validate(type, value, defs)`, answering in the value domain. The built-ins
implement it for the calendar types, `Keyword` (element types included),
`MapSet` (element types included) and `Regex`. A provider type with a
`transform` and neither `validate/3` nor an explicit `validator` is accepted
unchecked — the documented hole. A provider node with neither a transform nor a
validator is still checked by its kind.

Measured locally on a 20-tool module returning `ToolCall.TestFixtures.Address.t()`
versus `map()`: 87,672 B versus 61,620 B of beam, with compile time unchanged
(170.7 ms versus 170.8 ms, min of 5). The result IR embeds the struct object once
per tool; the input schema is byte-identical either way.

Not included: converting a value into a JSON value (struct → map, `Date` → ISO
8601) or a JSON string. That stays with the caller.

## Provider subsets

The same IR is normalized for the provider formats below. Runtime emitters exist
for OpenAI, Anthropic and MCP. OpenAI and Anthropic are precompiled per module;
MCP renders on demand from the tool IR, because its schema is the same
parameters object the other targets embed. A Gemini emitter is planned.

| | OpenAI | Anthropic | MCP |
|---|---|---|---|
| Shape | `{"type":"function","function":{...}}` | `{name, description, input_schema}` | `{name, description, inputSchema}` |
| Top level | must be an object | any JSON Schema | an object schema (`type: "object"`) |
| `strict: true` | sets the flag, makes every property required, closes every object, warns about parameters that cannot be typed | n/a | renders the closed subset; MCP has no flag |
| `$ref` / `$defs` | supported, strict mode included | supported | supported |
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
quoted AST) but the parameter stays optional. Module attribute defaults are
expanded to their value first when that value is a JSON literal; structs remain
non-literal. A literal that is valid JSON but outside the parameter's value
domain is also dropped, with a compile-time warning. Defaults are parsed against
the declared type recursively: nested `keyword(t)`, object/list fields and union
branches retain their values, and `char()`/`charlist()` values are rendered in
wire form. Boolean and nil `atom()` defaults are omitted; booleans are rejected
by the atom wire domain, and nil is omitted even when the type is nullable. A
reduced-arity call receives every required
argument plus a prefix
of the optional arguments; the generated per-tool runner constructs that call,
with `ToolCall.Runner` as the complex-tool fallback.

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

Measured locally on a 20-tool module (Elixir 1.20.5, OTP 29), 0.2 line: adding
one recursive type and one struct type to a 20-tool module changes `beam` size
by about +5 KB (47 KB to 52 KB) and does not move compile time measurably
(`Code.compile_string`, min of 5: 167 ms vs 158 ms, inside noise). `emit/3`
costs about 0.13 µs for the non-recursive module and 0.31 µs when a `$defs`
literal is present. On the generic runner, `run/3` costs about 1.4 µs for a
struct parameter and about 3 µs for a recursive one, because the nested
non-string-key check walks the value; the generated scalar fast path stays at
about 0.17 µs. These are dispatch costs, three orders of magnitude below a
provider round trip.

Measured locally on a 20-tool module (Elixir 1.20.5, OTP 29): a module whose
effective typedoc key map is empty reads the literals directly — `emit/3` costs
about 0.07 µs per call, `__schemas__/0` about 13 ns and `run/3` about 0.15 µs
for the generated scalar fast path. A local-type parameter that is already
documented by a `@doc` bullet or `@tool_param` description takes that same
direct path, because `Typedoc.apply/3` would not touch it. With a typedoc
companion present, `emit/3` costs about 0.14 µs; `run/3` uses the generated
per-tool IR and does not need the companion guard. A complex nested tool falls
back to the generic coercion path at roughly 0.5 µs. A module with an
undocumented local-type parameter whose type has no visible `@typedoc` still
takes the guarded path for `__tools__/0` / `__schemas__/0`. The first such call
pays roughly 16–26 µs because the failed `Code.ensure_loaded?/1` searches the
code path (the exact cost depends on the code path length); the per-companion,
per-function absence is cached for that generation, so later calls return the
phase-one literal without repeating the lookup. A fresh render of a runtime
`ToolCall.IR.Tool` costs about 0.5 µs per call. The embedded schemas add about
35 KB to the beam and 9 ms to compilation. A module built at runtime
(`ToolCall.IR.Tool`) is rendered on demand instead.

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

**Validation and coercion share the same IR.** The schema says `1.0` is a valid
integer; Elixir disagrees; `ToolCall.Coerce` bridges the gap instead of letting
the function crash. Scalar tools use generated coercion; complex shapes fall
back to the generic runner.

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

See [`roadmap.md`](roadmap.md) for the planned `0.2` / `0.3` / `0.4` stages,
release readiness work and current status.

## Design boundaries

These are intentional limits rather than missing implementation:

- `@typedoc` applies only to the parameter's directly declared local type,
  including local alias chains. It is not inherited by `list(address())`, map
  fields, remote types or provider types. `@typep` typedocs are discarded by
  Elixir before the Docs chunk exists.
- One tool is one schema: overloaded specs and two arities of the same function
  cannot both be exposed under the same name.
- Defaults that JSON cannot carry, notably tuples, are omitted. JSON numbers
  outside Erlang's finite float range fail in the decoder before the library
  sees them.
- `@doc` metadata-only entries have no description text. `@on_definition` is an
  accumulating hook shared with other libraries.
- Type providers resolve types, not typedoc descriptions.
- Another module's non-struct local types are not inlined, and a struct field
  typed with that module's `@typep` stays `{}`: only public types are in the
  types chunk.
- Struct field order is alphabetical, not `defstruct` order, so `required` is
  reproducible.
- Struct fields carry no description. A typespec has no per-field doc, so a
  nested object reaches the model as property names only; `@doc` and `@typedoc`
  describe parameters, not fields. Flatten the shape into parameters with
  `@doc` bullets, or explain it in the tool description, when field meaning
  matters.
- A struct defined in the same module as its tools takes its field names from
  the map in the generated `__struct__/0`, captured at definition time, and its
  field types from `t/0`; a field that `t/0` omits is typed `{}`. A module with
  no generated `__struct__/0` (a hand-written struct) falls back to `t/0` alone.
