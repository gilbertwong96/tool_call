# ToolCall

Derive LLM tool-call schemas from Elixir `@spec` and `@doc`, and dispatch the
call back to the function.

No DSL to maintain, no schema to keep in sync with the implementation.

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
  def get_weather(city, days \\ 3) do
    {:ok, %{city: city, days: days, temp: 21.5}}
  end
end
```

```elixir
ToolCall.emit(MyApp.Tools.Weather, :openai)

#=> [%{"type" => "function",
#=>    "function" => %{
#=>      "name" => "get_weather",
#=>      "description" => "Get the forecast for a city.",
#=>      "parameters" => %{
#=>        "type" => "object",
#=>        "properties" => %{
#=>          "city" => %{"type" => "string", "description" => "city name"},
#=>          "days" => %{"type" => ["integer", "null"], "minimum" => 1, ...}
#=>        },
#=>        "required" => ["city"],
#=>        "additionalProperties" => false
#=>      }}}]

ToolCall.run(MyApp.Tools.Weather, :get_weather, %{"city" => "Oslo"})
#=> {:ok, %{city: "Oslo", days: 3, temp: 21.5}}
```

## Why the typespec

`@spec` already states the contract, `@doc` already explains it, and Elixir
stores both as structured data at compile time. Tool definitions are the same
information in another format, so there is no reason for a second source of
truth.

The library derives everything at compile time. The IR and provider schemas are
built in `@before_compile`; a second compile phase in `@after_compile` reads the
just-compiled `Docs` chunk to pick up `@typedoc` text and embeds the result as
ordinary literals. No runtime path reads the `Docs` or `Dbgi` chunks: release
builds strip those chunks, which is exactly where Code.Typespec and
`Code.fetch_docs` read from. The typedoc companion is ordinary compiled code,
loaded on first use like any other module. Release `strip_beams: true` is
covered below.

## Releases and `strip_beams: true`

`mix release` uses `strip_beams: true` by default. ToolCall is designed for
that: every tool definition is derived at compile time, and the generated
`__tools__/0`, `__schemas__/0` and `__run__/2` functions are ordinary code and
literal data. When `@typedoc` applies, the enriched literals live in a generated
companion module (`MyApp.Tools.Weather.__ToolCall__`) whose beam is written to
the application's compile path and copied into the release like any other beam.
Stripping removes the `Docs`/`Dbgi` chunks, not the generated functions, the
companion literals or the compiled schemas.

That means these keep working in a stripped release:

```elixir
ToolCall.emit(MyApp.Tools.Weather, :openai)
ToolCall.run(MyApp.Tools.Weather, :get_weather, args)
ToolCall.tools(MyApp.Tools.Weather)
ToolCall.describe(MyApp.Tools.Weather)
```

What stops working is runtime reflection that was never part of ToolCall:

```elixir
Code.Typespec.fetch_specs(MyApp.Tools.Weather)  #=> :error
Code.fetch_docs(MyApp.Tools.Weather)            #=> {:error, :chunk_not_found}
```

The library does not call either function at runtime. `@doc`, `@spec`, local
`@type` declarations and `@tool_param` overrides are consumed at compile time;
`@typedoc` is recovered in the compile-time `@after_compile` phase; the
resulting descriptions, types, defaults and schemas are embedded in the module
or its companion.

Two release-specific caveats:

- If a `ToolCall.TypeProvider` defines `coerce/1`, that provider module must be
  present in the release. It runs at dispatch time; do not put it in a
  `runtime: false` dependency if the tool uses it.
- Do not rebuild tools at runtime by reading Code.Typespec or Code.fetch_docs.
  Use the embedded IR from `ToolCall.tools/1`, or construct
  `ToolCall.IR.Tool` values explicitly.

`mix tool_call.export` is a build-time Mix task, not a runtime requirement.
Run it while building the release if you need a checked-in JSON file.

### Typedoc companion lifecycle

`@typedoc` text lives in the `Docs` chunk, which is only readable after the
module closes. Phase two creates the companion only when at least one
parameter description changed, and removes it when typedoc no longer applies.
The companion carries a compile-generation token; `__tools__/0` and
`__schemas__/0` use it only when the token matches the module's current
generation. A stale, partially written or failed companion therefore falls back
to the phase-one descriptions instead of serving old data.

Source-file modules persist the companion beam under
`Mix.Project.compile_path/0`; `Code.compile_string/1` and IEx (`nofile`)
modules keep it in memory only. The beam is not registered in Mix's compile
manifest:

- `mix clean` removes it with the build directory.
- Deleting a source module can leave its companion beam until the next
  `mix clean`. The generation token makes it harmless, and the unused beam may
  still be copied into a release.
- Upgrading from a ToolCall build that predates the companion marker requires
  one `mix clean`: such a beam is treated as foreign, so ToolCall warns and
  keeps phase-one descriptions rather than overwriting it.
- A user module named `<Module>.__ToolCall__` is never overwritten; ToolCall
  warns and keeps phase-one descriptions. Treat that name as reserved.

Phase two is best-effort. A missing `Docs` chunk warns when docs are enabled;
an undecodable chunk or a failed companion write also warns and leaves the
phase-one descriptions in place. A compile with `docs: false` is expected to
have no `Docs` chunk, so it skips the fallback silently. A structurally invalid
but term-decodable chunk is reported as corrupt, not as absent.

If a local-type parameter's type has no visible `@typedoc`, give the parameter a
`@doc` bullet or `@tool_param` description: typedoc adds nothing there, and an
undocumented local-type parameter keeps the module on the guarded accessor path.

## What you get

- `ToolCall.emit/3` — `:openai` (including `strict: true`) and `:anthropic`.
  For a module the schemas are rendered at compile time: a direct literal
  lookup when the effective typedoc key map is empty (no undocumented
  local-type parameter, or docs disabled), behind the companion guard
  otherwise.
- `ToolCall.run/3` — required/unknown argument checks, coercion, exception
  wrapping.
- `ToolCall.tools/1` — the IR, if you want to build your own emitter.
- `ToolCall.describe/2` — `%{module, name, description, parameters}` per tool,
  with no provider envelope, for clients that build the request themselves.
- `ToolCall.TypeProvider` — resolves custom remote types registered with
  `use ToolCall, types: [...]`.
- `mix tool_call.export` — the same schemas as JSON (`openai`, `anthropic` or
  `mcp`).

Both `emit/3` and `run/3` accept the module or, for `emit/3`, the IR directly:

```elixir
json = ToolCall.emit(MyApp.Tools.Weather, :openai, strict: true)
schema = ToolCall.emit(hd(ToolCall.tools(MyApp.Tools.Weather)), :anthropic)
```

## Custom types

Built-in remote types are resolved by a built-in provider. A user-defined type
gets a `ToolCall.TypeProvider` registered per tool module:

```elixir
defmodule MyApp.MoneyType do
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(Money, :t, []) do
    {:ok, %ToolCall.IR.Type{kind: :string, pattern: "^-?\\d+\\.\\d{2}$"}}
  end

  def resolve(_module, _function, _args), do: :error

  @impl true
  def coerce(value), do: {:ok, Money.new(value)}
end

defmodule MyApp.Tools do
  use ToolCall, types: [MyApp.MoneyType]

  @spec price(amount :: Money.t()) :: Money.t()
  def price(amount), do: amount
end
```

`resolve/3` receives the remote module, the type name and the already-resolved
argument types. Return `{:ok, %ToolCall.IR.Type{}}`, or `:error` to fall back to
`{}`. `coerce/1` is optional; it runs after the wire value has been coerced.
Providers are tried after the built-ins (`String`, `Keyword`, `Path`, calendar),
so a provider cannot replace them. `types:` is per module. The provider module
must be compiled before the tool module; the generated `require` adds that
compile dependency.

`Decimal.t()` is not built in; implement a provider for it, or use `String.t()`
and convert in the function.

## Conventions

- **Annotate arguments to name them.** `@spec f(city :: String.t())`, not
  `@spec f(String.t())`. Unnamed parameters fall back to the head variable (or
  `argN` when the head is `_`) with a warning. A bare type variable in a `when`
  spec counts as unnamed too: write
  `@spec id(value :: x) :: x when x: integer()`.
- **A default makes a parameter optional.** `def f(a, b \\ 1)` puts `a` in
  `required` and leaves `b` out. Defaults that are not literals (such as
  `DateTime.utc_now()`) are not sent to the model; the parameter is still
  optional. Defaults JSON cannot carry (tuples, non-string map keys) are
  dropped too, and a literal default that does not belong to the parameter's
  value domain is dropped with a compile-time warning. `~s`, `~c` and
  `~w` sigil defaults are kept (a charlist default is sent as a string); sigils
  that interpolate or build non-JSON values (dates, regexes) are dropped. An
  `atom()` default is sent as its string form, including `true` and `false`.
- **Names must be unique and provider-safe.** A duplicate argument name is
  exposed as `name_2` with a warning; an unnamed `_` argument falls back to the
  head variable or `argN`. Provider tool names must match
  `^[a-zA-Z0-9_-]{1,64}$`: a function named `find?` warns, and the export task
  refuses to write it. Two arities of the same function share one tool name, so
  only the first is exposed.
- **`@doc` first paragraph is the description.** Bullets inside a `## Parameters`
  heading become per-parameter descriptions: `* city - city name` (backticks
  around the name are optional). Indented continuation lines are appended;
  a blank line ends the current bullet's continuation, and nested bullets (and
  their continuations) are not parameters.
- **`@doc false` opts a function out** of the tool list.
- **`@type` declarations in the same module are resolved**, including `@typep`
  and `@opaque`, with parameters (`@type pair(a) :: {a, a}`). Recursive
  definitions stop at the first re-entry and that reference becomes `{}`.
- **`@typedoc` is a fallback parameter description.** A parameter declared as a
  local `@type` or `@opaque`, directly or wrapped as `<type>() | nil`, uses the
  type's typedoc when the parameter has no description. Parameterized local
  types work too: `pair(integer())` uses the typedoc of `pair/1`. Precedence is
  `@tool_param` description, then a `@doc` `## Parameters` bullet, then
  `@typedoc`, then no description; an empty-string `@tool_param` suppresses the
  fallback. Nested and wrapped uses such as `list(address())` or
  `%{address: address()}` do not inherit typedoc. `@typep` is unsupported for
  descriptions because Elixir discards its typedoc at definition time; the
  private type is still resolved for the schema. `@typedoc false` is hidden too.
- **Large integers travel as strings.** Opt in per argument:

  ```elixir
  @tool_param %{fun: :transfer, name: "user_id", wire: :string_integer,
                description: "Snowflake id"}
  ```

  The `:fun` key scopes the override to one function; without it the override
  is ignored with a compile-time warning. A misspelled function or argument name
  warns too. Unknown keys and a non-string `:description` are ignored with a
  warning; duplicate entries for the same argument warn because only one is used.
  A `:description` of `nil` leaves the doc description in place; an empty string
  clears it.

## Errors

`ToolCall.run/3` never raises for bad input; it returns one of:

| Error | Meaning |
|---|---|
| `{:unknown_tool, name, known}` | no tool with that name |
| `{:unknown_arguments, names}` | keys the schema does not declare |
| `{:non_string_arguments, keys}` | `args` used atom or other non-string keys; JSON objects decode to strings |
| `{:invalid_arguments, args}` | `args` was not a map (a provider may hand back a list or a scalar) |
| `{:missing_argument, name}` | a required argument is absent |
| `{:argument_gap, missing, dropped}` | a later optional argument was supplied after an omitted optional one, so Elixir would shift it into the wrong slot; a required argument after an omitted optional one is fine |
| `{:invalid_argument, {name, reason}}` | coercion failed, e.g. `{:expected_integer, "1.5"}` |
| `{:raised, message}` | the function raised |
| `{:thrown, value}` / `{:exited, reason}` | the function threw or exited |

Top-level argument maps use string keys, as JSON decodes them, and nested object
values should too; `keyword(t)` values also accept atom keys because a keyword
list is their value domain.

A raised exception is also logged with its stacktrace at `:error`; the model only
sees `{:raised, message}`. A tool that raises is a bug, not a model error — return
`{:error, reason}` for input the model can fix.

Send the error back to the model as the tool result — the reason is plain data
on purpose:

```elixir
case ToolCall.run(MyApp.Tools.Weather, call_name, call_args) do
  {:ok, value} -> inspect(value)
  {:error, reason} -> inspect(reason)
end
```

## Caveats

- `Date.t()`, `Time.t()`, `DateTime.t()` and `NaiveDateTime.t()` reach the model
  as strings (`format` is set for date/time/date-time; a naive datetime has no
  offset to describe) and are parsed from ISO 8601 before dispatch. An
  unparsable value is `{:invalid_argument, {name, {:invalid_date, value}}}`.
- **Every string parameter must be valid UTF-8 at runtime.** JSON strings are
  Unicode; if a provider or direct caller hands the dispatcher invalid UTF-8,
  it returns `{:invalid_argument, {name, {:invalid_utf8, value}}}` instead of
  raising. This applies to `String.t()`, `binary()`, `bitstring()`, patterns,
  `charlist()`, `char()`, atoms, enums and keyword keys.
- `struct()` is not reconstructed. It is represented as an open object; the
  function receives a plain map. Use a concrete `%MyStruct{}` type with a
  `ToolCall.TypeProvider` if the function needs the struct.
- `atom()` is described as an unconstrained string. The dispatcher maps a string
  to an atom only when that atom already exists in the VM; unless the type is
  nullable it rejects `null` and booleans. Prefer `:a | :b` so the schema carries
  an `enum`.
- Wire shapes are restored before dispatch: `%{a: integer()}` arrives with atom
  keys, `keyword(t)` as a keyword list, `charlist()` as a charlist, `char()` as
  a codepoint, and tuples as Erlang tuples. Open maps and `%{k() => v}` keep the
  string keys JSON gives them. `keyword/1` keys must already exist as atoms in
  the VM, like `atom()`; an unknown key is `{:unknown_atom, key}`.
- `strict: true` makes optional arguments required and nullable. An explicit
  `null` for a non-nullable optional argument or field is treated as absent; if
  the type already accepts `nil`, the value is passed through as `nil` and can
  override a default. For `any()`, an enum containing `nil`, or a union with
  such a branch, explicit `null` reaches a provider `coerce/1` as a normal value.
- The return type is not checked: results are returned as plain terms and must be
  JSON-encodable.

## Status

`0.1.0-dev`. Working: compile-time derivation, local `@type` resolution, typedoc
fallback parameter descriptions, the type subset in
[`docs/design.md`](docs/design.md), OpenAI (with `strict: true`) and Anthropic
emitters, custom type providers, coercion, dispatcher, compile-time warnings for
unnamed arguments, missing `@spec`, unrepresentable types and stray
`@tool_param` entries.

Not implemented yet: recursive types (`$ref`/`$defs`), struct field extraction
with `@enforce_keys`, result encoding, Gemini/MCP `emit/3` targets (MCP export
exists), streaming deltas, approval hooks, timeouts.

## Installation

```elixir
def deps do
  [tool_call: "~> 0.1"]
end
```

`0.1.0` is not on Hex yet; until then use a `path:` (or `git:`) dependency.
Elixir `~> 1.18` (built-in `JSON`) and Erlang/OTP 27.1+; no runtime dependencies.
The OTP floor is enforced at compile time.

## Export

`mix tool_call.export` writes the derived schemas as JSON, without a provider
client in the loop:

```sh
mix tool_call.export                          # OpenAI function objects
mix tool_call.export MyApp.Tools.Weather      # one module
mix tool_call.export --format anthropic       # Anthropic tool definitions
mix tool_call.export --format mcp --out priv/tools.json
mix tool_call.export --strict                 # strict JSON Schema subset
```

Without module arguments it discovers every module of the current application
that exports `__tools__/0`; `--app` selects another application. Discovery
loads those modules (`Code.ensure_loaded?/1`), so `@on_load` callbacks run; pass
module names to avoid it. The output is indented JSON with sorted keys, sorted by
module and with declaration order preserved inside a module, so a committed file
stays stable.

Formatting uses `json:format/1`, which is why the project floor is Erlang/OTP
27.1. The formatter is OTP's, so a committed file is reproducible with the same
OTP version; an OTP upgrade can reflow it (the JSON stays equivalent). The task
refuses tool names outside
`^[a-zA-Z0-9_-]{1,64}$` instead of writing a file the provider will reject.

If your client owns the request format, `ToolCall.describe/2` returns the same
information without a provider envelope:

```elixir
[%{name: "get_weather", description: _, parameters: params} | _] =
  ToolCall.describe(MyApp.Tools.Weather, strict: true)
```

## Documentation

- [`docs/usage.md`](docs/usage.md) — end-to-end usage, dispatch, the loop.
- [`docs/design.md`](docs/design.md) — architecture, type mapping, provider subsets.
- [`docs/pitfalls.md`](docs/pitfalls.md) — compile-time traps and what is done about each.
- [`docs/number-handling.md`](docs/number-handling.md) — precision across Elixir, JSON and providers.

## Development

```sh
mix deps.get
mix ci
```

`mix ci` is the full gate: `compile --warnings-as-errors`,
`format --check-formatted`, `test`, `credo --strict`, `dialyzer`,
`ex_dna --max-clones 0` and `reach.check --arch --smells`. The quality config
(`.credo.exs`, `.reach.exs`, the alias) was installed by VibeKit;
`mix test --cover` reports line coverage.

## License

MIT
