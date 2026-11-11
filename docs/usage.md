# Usage

End-to-end: define a tool, emit the schema your provider wants, dispatch the
call back to the function. The library does not speak HTTP and does not encode
JSON — Elixir ≥ 1.18 ships `JSON`, so a zero-dependency setup works.

## 1. Define a tool module

```elixir
defmodule MyApp.Tools.Weather do
  use ToolCall

  @doc """
  Get the forecast for a city.

  ## Parameters
    * `city` - city name, e.g. "Oslo"
    * `days` - how many days ahead (1-7)
  """
  @spec get_weather(city :: String.t(), days :: pos_integer() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def get_weather(city, days \\ 3) do
    {:ok, %{city: city, days: days, temp: 21.5}}
  end
end
```

Everything else is derived. What the library reads:

| You write | It reads |
|---|---|
| `@spec f(city :: String.t())` | parameter name `city` and its type. Without `city ::` the name is taken by position from a `@doc` bullet when available, then falls back to the head variable (or `argN`) with a warning; a bare type variable in a `when` constraint counts as unnamed |
| `def f(city, days \\ 3)` | `days` is optional, `3` is emitted as `default`; a module attribute value is expanded when it is a JSON literal |
| first `@doc` paragraph | tool `description`; a leading `# Title` is stripped and a leading level-2+ section heading is omitted in favor of its body |
| `* name - text` (also `+` and `-`; optional `(Type.t())`) under `## Parameters` (also `Params`, `Options`, `Arguments`, `Args`; a trailing `:` and up to three spaces of heading indentation are accepted) | per-parameter `description` (indented continuation lines are joined; nested bullets, their continuations, and other shapes are ignored). `## Options` bullets describe keyword-option keys: they do not name or warn about parameters, and the section is not sent to the model. |
| `@doc false` | the function is not a tool |
| no `@spec` | the function is skipped with a warning |
| `@type` in the same module | inlined; a remote type without a provider stays `{}` |
| `@typedoc` on a local `@type` or `@opaque` | fallback parameter description when no `@doc` bullet or `@tool_param` description exists; local alias chains are followed to the nearest documented type; `@typep` is unsupported |
| `use ToolCall, types: [MyProvider]` | resolves custom remote types through `ToolCall.TypeProvider` |
| a duplicate name, e.g. `f(city :: String.t(), city :: integer())` | the second becomes `city_2`, with a warning |
| `_ :: String.t()` | the head variable name, or `argN` if that is `_` too |

Boolean and nil `atom()` defaults are omitted, including nullable `atom() | nil`.

### Custom types

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
Providers are tried after the built-ins (`String`, `Keyword`, `Path`, the calendar
types, `MapSet`, `Regex`), so a provider cannot replace them; for one of those,
declare the parameter as the wire shape you want (`String.t()`, `list(t)`) and
convert in the function. `types:` is per module. The provider module
must be compiled before the tool module; the generated `require` adds that
compile dependency.

`t:MapSet.t/0`, `t:MapSet.t/1` and `t:Regex.t/0` are built in: a set travels as an
array of its elements and a regex as its source string (compiled with `u` at
dispatch). `Decimal.t()` is not built in; implement a provider for it, or use
`String.t()` and convert in the function.

### Compile-time conventions

- **Annotate arguments to name them.** `@spec f(city :: String.t())`, not
  `@spec f(String.t())`. Unnamed parameters can be named by position from
  `@doc` parameter bullets; otherwise they fall back to the head variable (or
  `argN` when the head is `_`) with a warning. A bare type variable in a `when`
  spec counts as unnamed too: write
  `@spec id(value :: x) :: x when x: integer()`.
- **A default makes a parameter optional.** `def f(a, b \\ 1)` puts `a` in
  `required` and leaves `b` out. Defaults that are not literals (such as
  `DateTime.utc_now()`) are not sent to the model; the parameter is still
  optional. A module attribute default (`def f(x \\ @default)`) is expanded
  when its value is a JSON literal; struct values are still dropped. Defaults
  JSON cannot carry (tuples, non-string map keys) are dropped too, and a literal
  default that does not belong to the parameter's value domain is dropped with
  a compile-time warning. `~s`, `~c` and `~w` sigil defaults are kept (a
  charlist default is sent as a string); sigils that interpolate or build
  non-JSON values (dates, regexes) are dropped. A non-boolean `atom()` default
  is sent as its string form; `true`, `false` and `nil` defaults are omitted.
  The atom wire domain rejects booleans, and nil defaults are kept out even for
  nullable atom types. Defaults are parsed
  against the declared type at any depth: nested `keyword(t)`, object/list
  fields and union branches keep their values, and nested `char()`/`charlist()`
  values become strings in the schema.
- **Names must be unique and provider-safe.** A duplicate argument name is
  exposed as `name_2` with a warning; an unnamed `_` argument falls back to the
  head variable or `argN`. Provider tool names must match
  `^[a-zA-Z0-9_-]{1,64}$`: a function named `find?` warns, and the export task
  refuses to write it. Two arities of the same function share one tool name, so
  only the first is exposed.
- **`@doc` first paragraph is the description.** A leading `# Title` is
  stripped; a leading level-2+ section heading is omitted and its body is used.
  Bullets inside a `## Parameters` heading become per-parameter descriptions:
  `* city - city name`, `+ city - city name` or `- city - city name`
  (backticks around the name are optional; an optional type annotation such as
  `(String.t())` is ignored). Indented continuation lines are appended; a blank
  line ends the current bullet's continuation, and nested bullets (and their
  continuations) are not parameters.
- **`@doc false` opts a function out** of the tool list.
- **`@type` declarations in the same module are resolved**, including `@typep`
  and `@opaque`, with parameters (`@type pair(a) :: {a, a}`). Recursive
  definitions stop at the first re-entry and that reference becomes `{}`.
- **`@typedoc` is a fallback parameter description.** A parameter declared as a
  local `@type` or `@opaque`, directly or wrapped as `<type>() | nil`, uses the
  type's typedoc when the parameter has no description. Parameterized local
  types work too: `pair(integer())` uses the typedoc of `pair/1`; a local alias
  chain such as `@type location :: address()` follows to `address()` when
  `location` has no typedoc, including current-module `__MODULE__` or alias
  references in the alias body. Precedence is
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

- **An argument with no JSON type hides the tool.** `term()`, `any()`, a remote
  type with no provider, or an `@opaque` struct makes the schema undescribable,
  so the function is skipped like `@doc false` and the compile warns with the
  parameter name. Narrow the argument, add a `TypeProvider`, or opt out with
  `@doc false`. An untyped field *inside* an object or array keeps the tool and
  renders as `{}`.
- **Typedoc companions are written through Mix.** `@typedoc` fallback
  descriptions are stored next to the compiled beam via
  `Mix.Project.compile_path/0`. Compiling outside a Mix project (`elixirc`, an
  `elixir` script) still succeeds, but the companion is skipped with a warning
  and the phase-one descriptions are used.

### Recursive types

A local type that refers to itself becomes one `$defs` entry plus a `$ref`:

```elixir
@type tree :: %{value: integer(), children: [tree()]}

@doc "Walk a tree."
@spec walk(root :: tree()) :: map()
```

```json
{
  "properties": { "root": { "$ref": "#/$defs/tree" } },
  "required": ["root"],
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

The parameter itself is a `$ref`, so the body appears once. Mutual recursion
works the same way: every type on a cycle gets its own entry. A parameterized
recursive type names each instantiation with a short signature
(`tree_integer_40ca`), and a collision after truncation gets a `_2` suffix. Passing the call back through `ToolCall.run/3` coerces the value
at every level, so nested maps arrive with atom keys inside the function.

Two bounds stop a pathological cycle (`@type t(a) :: %{next: t({a, a})}`):
32 definitions per parameter and 8 instantiations per type. Past either bound
that reference is treated as `{}` and the compile warns.

Non-recursive local types are still inlined; their schemas are unchanged.

### Struct types

A concrete struct type becomes a closed object, and dispatch returns the
struct:

```elixir
defmodule MyApp.Address do
  @enforce_keys [:city]
  defstruct [:city, :street, country: "NO"]

  @type t :: %__MODULE__{city: String.t(), street: String.t() | nil, country: String.t()}
end

@doc "Ship to an address."
@spec ship(to :: MyApp.Address.t()) :: map()
```

```json
{
  "type": "object",
  "properties": {
    "city": { "type": "string" },
    "country": { "type": "string" },
    "street": { "type": ["string", "null"] }
  },
  "required": ["city"],
  "additionalProperties": false
}
```

- Field names come from `__struct__/0`; field types from the module's public
  `@type t`. A field that `t` omits stays `{}`, but still appears: the struct,
  not `t`, decides the field set.
- `required` comes from `@enforce_keys`.
- Omitted optional fields are not inserted before `struct/2`, so `defstruct`
  defaults apply. The schema does not carry the default value itself. An unknown
  key is rejected with `{:unknown_keys, keys}`.
- `@opaque t` is not extracted: it stays `{}` with the untyped warning.
- A `TypeProvider` always wins over extraction. Use one when a struct should
  travel as a scalar (`Decimal.t()` as a string, say) rather than as fields.
- A recursive struct (`%Node{children: [Node.t()]}`) uses `$defs` like a
  recursive local type.
- A nil branch makes the struct nullable: `Address.t() | nil` and a struct
  whose own `t` is `%__MODULE__{...} | nil` both accept null in the schema and
  nil from result validation. Any other union in `t` is non-literal, so every
  field becomes `{}` and the compile warns.
- `Mod.t(integer())` is resolved as the struct too, but type arguments are not
  substituted: fields come from `t/0`, and a parameterized-only `@type t/N`
  gives every field `{}` with a warning.
- A struct whose typespec chunk is missing (an in-memory `Code.compile_string/1`
  module, or `@compile {:debug_info, false}`) falls back to parsing the module's
  source file for `@type t` when that file is readable; `__MODULE__`, local
  types, simple aliases (including `as:` and multi-aliases) and aliases from an
  enclosing module resolve, and `@typep` aliases are read. Only aliases declared
  before the type apply; a `use`-injected alias is not visible in the source and
  degrades to `{}`. A module with no source (Livebook) warns "has no readable
  typespec" and keeps `{}` fields. A struct defined in the same module as its
  tools is exempt. See
  [`pitfalls.md`](pitfalls.md#a-struct-without-a-typespec-chunk-falls-back-to-its-source).
- Field properties carry no description: a typespec has no per-field doc. Put the
  field meaning in the tool description, or flatten the shape into parameters
  with `@doc` bullets.

`struct()` with no module is still an open object; the function receives a
plain map.

## 2. Emit a schema

```elixir
ToolCall.emit(MyApp.Tools.Weather, :openai)
ToolCall.emit(MyApp.Tools.Weather, :openai, strict: true)
ToolCall.emit(MyApp.Tools.Weather, :openai, strict: :fine_tuned)
ToolCall.emit(MyApp.Tools.Weather, :anthropic)
ToolCall.emit(MyApp.Tools.Weather, :mcp)
ToolCall.emit(MyApp.Tools.Weather, :gemini)

# several modules: concatenate the lists
tools = ToolCall.emit(A, :openai, strict: true) ++ ToolCall.emit(B, :openai, strict: true)
```

`strict: true` adds `"strict" => true`, makes every property required (nested
objects included), widens optional values to `["T", "null"]` and closes every
object. For an optional argument or field whose type does not accept `nil`, an
explicit `null` is treated as absent; if the type accepts `nil`, the value is
passed through and can override a default.

`strict: :fine_tuned` keeps that strict shape but also drops the keywords
fine-tuned models reject: `pattern`, `format`, numeric `minimum`/`maximum` and
array `minItems`/`maxItems`. It renders on demand instead of using the
precompiled strict literal. Use it when the tool targets a fine-tuned model.

`ToolCall.emit(module, :gemini)` returns one `{name, description, parameters}`
declaration per tool (the `functionDeclarations` entry), rendered on demand.
`parameters` is Gemini's 22-field OpenAPI 3.0 subset, not JSON Schema: types are
uppercase (`STRING`, `OBJECT`, `INTEGER`, …), `nullable: true` replaces a
`["T", "null"]` type, `additionalProperties` is dropped (Gemini objects are
always open), `prefixItems` is dropped (a tuple keeps only `minItems`/`maxItems`),
and a non-string enum is dropped. A recursive parameter raises
`ArgumentError`, because `parameters` has no `$defs`/`$ref`; send
`parametersJsonSchema` yourself if you need one. `strict` is ignored.

### When it happens

Everything is compile time. Inside `@before_compile` the library derives the IR
and renders the precompiled variants — `{:openai, false}`,
`{:openai, true}` and `{:anthropic, false}` — into literals stored in
`__schemas__/0`. MCP and Gemini are rendered on demand from the tool IR. A second compile phase (`@after_compile`) reads the
just-compiled `Docs` chunk for `@typedoc` fallback descriptions; if any apply,
the enriched literals live in a generated companion module and `__schemas__/0`
delegates to it. `ToolCall.emit/3` on a module still returns a precompiled
literal, so `strict` may be a runtime boolean and no schema is rendered per
call.

The accessors are direct when the module's effective typedoc key map is empty:
no parameter that still needs a description has a module-local declared type
(for example, every local-type parameter already has a `@doc` bullet or
`@tool_param` description), or the compile has `docs: false`. `__schemas__/0`
and `__tools__/0` then return the phase-one literals with no helper call. A
parameter gains a typedoc key only when its declared type is a module-local
type, directly or wrapped as `<type>() | nil`; `list(address())` and
`%{address: address()}` stay on the direct path. When at least one such
undocumented parameter exists and docs are enabled, a `@typedoc` companion may
exist, so the accessors call `Code.ensure_loaded?/1` and
`function_exported?/3` first and fall back to the phase-one literals when the
companion is stale or missing.

Measured locally on a 20-tool module (Elixir 1.20.5, OTP 29): with no
module-level timeout/approval/audit policy, a module with an empty typedoc key
map takes about 0.07 µs for `emit/3`, 13 ns for `__schemas__/0` and about
0.15 µs for `run/3` on the generated scalar fast path.
A local-type parameter that is already documented by `@doc` or `@tool_param`
takes that same direct path, because `Typedoc.apply/3` would not touch it. With
a typedoc companion present, `emit/3` takes about 0.14 µs; `run/3` uses the
generated per-tool IR without the companion guard. A complex nested tool falls
back to the generic coercion path at roughly 0.5 µs. A module with an
undocumented local-type parameter whose type has no visible `@typedoc` still
pays the guard on the first `__tools__`/`__schemas__` accessor call — roughly
16–26 µs because the failed `Code.ensure_loaded?/1` searches the code path,
which depends on the code path length. The absence is cached per companion,
function and generation, so later calls use the phase-one literal directly. A
fresh render of a runtime `ToolCall.IR.Tool` costs about 0.5 µs. The embedded
schemas add roughly 35 KB to the beam and 9 ms to compilation.

That is also why releases work: `mix release` strips the `Docs` and `Dbgi`
chunks, so Code.Typespec.fetch_specs/1 and `Code.fetch_docs/1` fail on the
compiled beam, and this library never calls them. See the release notes in
[`design.md`](design.md).

A `ToolCall.IR.Tool` — a tool built at runtime — is still rendered on demand.
That is the only path that pays for rendering.

## 3. Call the provider

```elixir
# OpenAI
%{"model" => "gpt-4.1", "messages" => messages,
  "tools" => MyApp.Tools.openai_tools()}

# Anthropic
%{"model" => "claude-sonnet-4-5", "max_tokens" => 1024, "messages" => messages,
  "tools" => ToolCall.emit(MyApp.Tools.Weather, :anthropic)}
```

The two protocols differ in exactly one place, and it matters for dispatch:
OpenAI returns `arguments` as a JSON **string**, Anthropic returns `input`
already **decoded**.

## 4. Dispatch a call

```elixir
defmodule MyApp.ToolRunner do
  @modules [MyApp.Tools.Weather, MyApp.Tools.Math]

  # OpenAI: arguments is a JSON string
  def openai_tool_result(%{"id" => id, "function" => %{"name" => name, "arguments" => json}}) do
    content =
      with {:ok, args} <- JSON.decode(json),
           {:ok, value} <- run(name, args) do
        JSON.encode!(%{ok: true, result: value})
      else
        {:error, reason} -> JSON.encode!(%{ok: false, error: render(reason)})
      end

    %{"role" => "tool", "tool_call_id" => id, "content" => content}
  end

  # Anthropic: input is already a map
  def anthropic_tool_result(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    content =
      case run(name, input) do
        {:ok, value} -> JSON.encode!(value)
        {:error, reason} -> render(reason)
      end

    %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
  end

  defp run(name, args) do
    module = Enum.find(@modules, &(name in ToolCall.tool_names(&1)))

    if module,
      do: ToolCall.run(module, name, args),
      else: {:error, {:unknown_tool, name, []}}
  end

  defp render({:invalid_argument, {name, reason}}), do: "#{name}: #{inspect(reason)}"
  defp render(other), do: inspect(other)
end
```

Measured output for a good call and two bad ones:

```elixir
%{"role" => "tool", "tool_call_id" => "call_1",
  "content" => "{\"ok\":true,\"result\":{\"temp\":21.5,\"city\":\"Oslo\",\"days\":5}}"}

# the model sent a string where the schema says integer
"content" => "{\"error\":\"days: {:expected_integer, \\\"5\\\"}\",\"ok\":false}"

# the model invented an argument
"content" => "{\"error\":\"{:unknown_arguments, [\\\"c\\\"]}\",\"ok\":false}"
```

### Result validation

`run/4` can check the function's raw return value against its `@spec` return
type:

```elixir
@spec get_weather(city :: String.t()) :: {:ok, map()} | {:error, String.t()}

ToolCall.run(MyApp.Tools.Weather, :get_weather, %{"city" => "Oslo"},
  validate_result: true)
#=> {:ok, %{temp: 21.5}}
#=> {:error, {:invalid_result, {:no_variant_matched, {:ok, "oops"}}}}
```

- It validates the **raw** return (`{:ok, value}`, not `value`) before the
  `{:ok, _}` / `{:error, _}` unwrap.
- It is off by default; with no module-level timeout/approval/audit policy,
  `run/3` uses the generated fast path and never validates.
- A tool with a `no_return()` spec has no result type and skips validation.
- A function that raises keeps `{:error, {:raised, message}}`, not
  `{:invalid_result, _}`.

Validation is strict to the value domain: `float()` rejects `1`, `String.t()`
requires valid UTF-8, `char()` is a codepoint and `charlist()` a list, while
`binary()`/`bitstring()` accept raw bytes. `nil` is valid for a `T | nil` return.
`keyword(t)` and `MapSet.t(t)` also check their element types. A provider type
(`Date.t()`, `MapSet.t()`, …) is checked through the provider's optional
`validate(type, value, defs)`; a provider type with a transform and no
`validate/3` is accepted unchecked. `Path.t()` is a UTF-8 string here: a
non-UTF-8 path fails validation. `atom()` results follow the value domain
(booleans are atoms), unlike `atom()` arguments, which follow the wire domain.
A `no_return()` result is never validated. A result type that renders `{}` —
`term()`, an unknown remote type, `fun()`/`pid()`, an `@opaque` struct, or a
budget-truncated type — accepts any value; the compile warns, because
`validate_result: true` cannot check it. A provider `validator` on the node
suppresses the warning and is used instead. The warning walks the result and
reports paths: `"a"` for a field, `"*"` for open-object values, `"[]"` for array
items, `"[1]"` for a tuple position. A validator on a node stops the walk at
that subtree, so `map()` and `list()` results report `"*"`/`"[]"` unless their
values use a fixed shape. An improper list or an exotic map key
(a tuple, a map) is `{:invalid_result, ...}`, not a raise. A struct result is
checked field by field against its `@type t`, so a field whose `defstruct`
default is nil must be declared `T | nil`. A fixed-shape map type is closed and
rejects a struct value. The result also shares the tool's 32-definition budget
with the parameters: if they exhaust it, the result degrades to `:any` and
validation accepts anything.

### Approvals

An approval policy is a module implementing `ToolCall.Approval`:

```elixir
defmodule MyApproval do
  @behaviour ToolCall.Approval

  @impl true
  def check(%ToolCall.IR.Tool{name: "transfer_money"}, args, _context) do
    if args["amount"] > 1_000,
      do: {:required, "amount over threshold"},
      else: :approve
  end

  def check(_tool, _args, _context), do: :approve
end

use ToolCall, approval: MyApproval
```

The module option also accepts `:granted` or `:denied` as a module-wide decision.
`run/4` then answers one of:

```elixir
{:ok, value}
{:pending, %ToolCall.Approval.Request{}}
{:error, {:approval_denied, reason}}
```

The pending request carries `id`, `module`, `tool`, `args`, `reason`,
`context` and `inserted_at`. The application persists it, asks a human, and
resumes with the **stored** arguments. The struct itself contains no pids or
closures, but `args` and `context` are caller-provided: they are serializable
only when those values are.

```elixir
ToolCall.run(request.module, request.tool, request.args,
  approval: :granted, context: request.context)
```

- `approval: :granted` / `:denied` override the module policy; an explicit
  policy module overrides it too. `approval: nil` disables a module policy for
  one call.
- `context:` reaches `check/3`.
- The approval policy runs before the timeout policy and the task; a pending
  request returns without evaluating the timeout policy, starting a task or
  invoking the function.
- This is a mechanism, not a workflow: no storage, expiry, retry or
  double-execution guard. Never accept fresh model arguments for an approved
  call; use the stored ones. The agent runtime or application owns the pending
  state.
- The request stores `args` and `context`, not one-off execution options.
  Re-supply `validate_result:`, `timeout:`, `audit:` and `task_supervisor:` on
  resume if the original call used them; module-level policies are re-read. The
  pending audit entry carries `approval_request_id`; a resumed entry does not,
  so pass `request.id` in the resume context to correlate audit records.
- A module option is checked for `check/3` when options are validated; a
  module-level policy is checked when the module is resolved. An audit module is
  checked for `record/1` the same way. Module-level option values are not
  compile-time validated: a typo such as `approval: :grant` or
  `audit: :granted` compiles and fails when the module is resolved. Call
  `ToolCall.validate_policies!/1` at startup to reject it before the first
  dispatch.

`ToolCall.Runner.resolve/4` and `execute/2` expose the same hook: `resolve`
stores the policy and the context, `execute` checks it, so a future runtime can
resolve, gate and then execute. Pass `context:` to `resolve` (it is stored on
the call) or override it on `execute`.

### Audit

An audit policy is a module implementing `ToolCall.Audit`:

```elixir
defmodule MyAudit do
  @behaviour ToolCall.Audit

  @impl true
  def record(%ToolCall.Audit.Entry{} = entry) do
    MyApp.AuditLog.insert(entry)
  end
end

use ToolCall, audit: MyAudit
```

`run/4 audit:` overrides the module policy; `audit: nil` disables it. The hook
receives one entry per dispatch attempt:

```elixir
%ToolCall.Audit.Entry{
  id: "...", at: ~U[...], module: MyApp.Tools, tool: "transfer_money",
  args: %{"amount" => 100}, context: %{user_id: 42},
  outcome: :ok, duration_us: 1234, error: nil,
  approval_request_id: nil, timeout: nil
}
```

- `outcome` is `:ok`, `:error`, `:raised`, `:pending`, `:denied`, `:timeout`,
  `:invalid_arguments` or `:unknown_tool`; resolve failures, non-map arguments,
  unknown tools and exceptions from a resolve/execute policy are recorded too.
  An approval or other dispatch exception is an `:error` with
  `error: {:exception, message}`; a timeout policy failure is an `:error` with
  `error: {:invalid_timeout, reason}`.
- The outcome comes from the dispatch path, not from the error tuple: a tool
  returning `{:error, {:timeout, ...}}` or `{:error, {:approval_denied, ...}}`
  is recorded as `:error`, not as a dispatch timeout or denial.
- `duration_us` measures the phase that produced the outcome: resolve for an
  argument error, execute for an invoked call, and zero for an unknown tool or
  non-map arguments. Policy exceptions and invalid runtime IR use the phase
  that raised; this is not a total dispatch latency. The result value is never
  recorded.
- The hook is synchronous. This is a hook, not a store: persistence, redaction,
  retention and a fail-closed policy are the application's. The library ignores
  an exception from `record/1`, so a broken audit does not change the tool
  result; a module without `record/1` raises `ArgumentError` before the hook
  runs. Policy and hook execution is not covered by a timeout.
- `args` and `context` are raw; redact them in `record/1` when they contain
  secrets.

### Timeouts

`run/4` accepts a per-call timeout; without one the call runs in the caller
(unless `:task_supervisor` is given, which starts a task even for `:infinity`):

```elixir
ToolCall.run(MyApp.Tools, :slow_query, args, timeout: 5_000)
#=> {:error, {:timeout, 5_000}}
```

`ToolCall.Runner.resolve/4` and `execute/2` expose the same boundary: `resolve`
performs checks, coercion and positional construction, and stores the timeout
constant and an optional timeout policy on the call; `execute` checks approval,
then evaluates the policy and invokes the function, with an optional timeout:

```elixir
{:ok, call} = ToolCall.Runner.resolve(MyApp.Tools, tool, args)
ToolCall.Runner.execute(call, timeout: 5_000)
```

Set a default or a policy at compile time:

```elixir
use ToolCall, timeout: 5_000

# or per tool
defmodule MyTimeouts do
  @behaviour ToolCall.Timeout

  def timeout(%ToolCall.IR.Tool{name: "slow_query"}, _args, _context), do: 30_000
  def timeout(_tool, _args, _context), do: 5_000
end

use ToolCall, timeout: MyTimeouts
```

- `timeout: :infinity` disables the module policy for one call.
- `context: term` is passed to the timeout, approval and audit policies; use it
  for per-request budgets or user/tenant data. `resolve` stores it for
  `execute` unless `execute` overrides it.
- The timeout policy is evaluated by `execute/2`, after approval and before
  the task. It receives the validated raw argument map, not the coerced values;
  an invalid call or a denied/pending approval returns before the policy runs.
- `task_supervisor: MyApp.TaskSupervisor` runs the invocation under a
  `Task.Supervisor` instead of a task linked to the caller, including a timeout
  supplied by the module. With `timeout: :infinity` a supervisor still starts a
  task. An unreachable or invalid supervisor answers
  `{:error, {:task_supervisor, reason}}`.
- Approval, timeout and audit policies run synchronously in the caller; only
  the invocation and its result validation are covered by the timeout. Keep
  policies fast; the overall deadline is the caller's.
- The timeout wraps the function invocation and its result validation; argument
  validation and coercion happen before the task starts. A resolve error is
  returned without starting a task.
- It is a per-invocation cap, not a run deadline. The caller or agent framework
  owns the overall deadline.
- A timeout is a hard kill, not a cancellation: see
  [`pitfalls.md`](pitfalls.md#a-timeout-is-a-hard-kill-not-a-cancellation).

### Startup validation

Module-level policies can be checked before the first dispatch:

```elixir
:ok = ToolCall.validate_policies!(MyApp.Tools)
```

It validates `use ToolCall, timeout: ...`, `approval: ...` and `audit: ...`
values and callbacks, and raises `ArgumentError` for an invalid value. One-off
`run/4` options are checked when the call is made.

To wire it into application startup, add the one-shot supervision child before
the processes that dispatch tools:

```elixir
children = [
  {ToolCall.PolicyValidation, [MyApp.Tools, MyApp.OtherTools]},
  # ...
]
```

Use one child per supervisor with the complete module list. The child id is
fixed (`ToolCall.PolicyValidation`), so two children with that id conflict in
the same supervisor. Validation runs synchronously during child start, before
later children start, and is not repeated by later supervisor restarts.

The child returns `:ignore`, so it does not stay in the supervision tree. An
invalid policy raises `ArgumentError` during child start; under a supervisor
that fails application startup.

### Streaming

A streamed response delivers a tool call in pieces. `ToolCall.Stream` folds the
chunks into complete calls, ready for `run/3`:

```elixir
{:ok, calls} = ToolCall.Stream.aggregate(chunks, :openai)
#=> [%{id: "call_1", name: "get_weather", arguments: %{"city" => "Oslo"}}]

for call <- calls do
  ToolCall.run(MyApp.Tools.Weather, call.name, call.arguments)
end
```

The accumulator form fits a chunk-by-chunk consumer:

```elixir
acc = ToolCall.Stream.new(:anthropic)
acc = Enum.reduce(chunks, acc, &ToolCall.Stream.feed(&2, &1))
{:ok, calls} = ToolCall.Stream.finish(acc)
```

- `:openai` — Chat Completions `delta.tool_calls` fragments, keyed by `index`.
  Only the **first choice** is aggregated; stream with `n = 1` or split choices
  yourself. The Responses API uses a different event shape and is not handled.
- `:anthropic` — Messages `content_block_start` for a `tool_use` block plus
  `input_json_delta` fragments; a block with no fragments uses its initial
  `input` (`{}` for no arguments).
- `:gemini` — the first candidate's `streamGenerateContent` parts with a
  complete `functionCall`. Gemini has no call id, so `id` is `nil`.

The concatenated JSON is decoded with the standard `JSON` module, so
`arguments` is a map. Invalid JSON, or an Anthropic `input` that is not a map
when there are no fragments, is
`{:error, {:invalid_stream_arguments, {id, name, payload}}}`; a call that never
receives a name is `{:error, {:missing_name, id}}`. Chunks that carry no
tool-call data (text deltas, metadata) are ignored, and an empty stream is
`{:ok, []}`.

## 5. Export the schemas

```sh
mix tool_call.export                              # OpenAI function objects
mix tool_call.export --format anthropic           # Anthropic tool definitions
mix tool_call.export --format mcp --out priv/tools.json
mix tool_call.export --format gemini --out priv/gemini_tools.json
mix tool_call.export --strict
mix tool_call.export --fine-tuned
mix tool_call.clean                               # remove orphaned typedoc companions
```

`--format` is `openai` (default), `anthropic`, `mcp` or `gemini`; `--strict`
renders the strict subset for OpenAI and MCP (ignored by the other two);
`--fine-tuned` implies `--strict` and drops `pattern`, `format` and numeric/array
bounds; `--app` discovers another application. Gemini output is a `tools` request value:
`{"tools": [{"functionDeclarations": [...]}]}`. Without
module arguments every module in the app that exports `__tools__/0` is included.
The output indents two spaces, sorts object keys and modules, and keeps
declaration order inside a module, so a committed file stays stable across runs.

Formatting uses `json:format/1`, which is why the project floor is Erlang/OTP
27.1+. The formatter is OTP's: the same OTP version reproduces the file, while an
upgrade can reflow it without changing the JSON.
Tool names outside `^[a-zA-Z0-9_-]{1,64}$` are refused.

The task currently formats with OTP's `json:format/1`, not Elixir's `JSON`; the
library itself still has no runtime JSON dependency. When the request is built
somewhere else, `ToolCall.describe/2` returns
`%{module, name, description, parameters}` for every tool — the same data
without a provider envelope.

## 6. The loop

```elixir
def ask(messages, rounds \\ 0)
def ask(_messages, rounds) when rounds > 8, do: {:error, :too_many_rounds}

def ask(messages, rounds) do
  %{"choices" => [%{"message" => message}]} = post_chat(messages)

  case message["tool_calls"] do
    [] ->
      {:ok, message["content"]}

    calls ->
      results = Enum.map(calls, &MyApp.ToolRunner.openai_tool_result/1)
      ask(messages ++ [message | results], rounds + 1)
  end
end
```

## 7. Runtime behaviour

| Input | Result |
|---|---|
| `%{"city" => "Oslo"}` | `{:ok, %{city: "Oslo", days: 3, temp: 21.5}}` — trailing defaults fill in |
| `%{}` | `{:error, {:missing_argument, "city"}}` |
| `%{"days" => 5}` | `{:error, {:missing_argument, "city"}}` |
| `%{"b" => 2}` on `def f(a \\ 1, b \\ 2)` | `{:error, {:argument_gap, "a", ["b"]}}` — a reduced-arity call would bind `2` to `a`; use `%{"a" => 2, "b" => ...}` |
| `%{"b" => 2}` on `def f(a \\ 1, b)` | `{:ok, {1, 2}}` — Elixir can omit `a` while keeping required `b` |
| `%{"city" => "Oslo", "days" => 1.5}` | `{:error, {:invalid_argument, {"days", {:expected_integer, 1.5}}}}` |
| an invalid UTF-8 binary in any string argument | `{:error, {:invalid_argument, {name, {:invalid_utf8, value}}}}` |
| `%{"city" => "Oslo", "days" => nil}` | `{:ok, %{... days: nil}}` — `days` is nullable, so explicit null is preserved |
| `[1, 2]` instead of a map | `{:error, {:invalid_arguments, [1, 2]}}` |
| a raising function | `{:error, {:raised, "..."}}` |

### Error terms

`ToolCall.run/3` and `run/4` return one of the following for bad input or a
policy error. Invalid `run/4` options raise `ArgumentError`. An invalid explicit
`:timeout` raises
when a known tool is resolved or `execute/2` runs; an unknown tool or non-map
`args` returns before timeout validation. A policy exception that is not a
returned timeout error is re-raised after the audit entry is written:

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
| `{:timeout, ms}` | the invocation exceeded its timeout |
| `{:invalid_timeout, reason}` | the timeout policy raised or returned an invalid value |
| `{:task_supervisor, reason}` | the configured supervisor is unreachable or invalid |
| `{:approval_denied, reason}` | the approval policy denied the call |
| `{:invalid_approval, term}` | the approval policy returned an unknown term |
| `{:invalid_result, reason}` | `validate_result: true` rejected the raw return |

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

## 8. Rules and caveats

- **A raised exception is logged** with its stacktrace at `:error`; the model
  only sees `{:raised, message}`. Raising is for bugs — return `{:error, reason}`
  for anything the model can fix.
- **Tool results must be JSON-encodable.** `{1, :ok}` and `[a: 1]` raise
  `Protocol.UndefinedError` in `JSON.encode!/1`; return maps, lists and scalars,
  or send `inspect/1` as the content.
- **`Date.t()` / `Time.t()` / `DateTime.t()` / `NaiveDateTime.t()` are parsed
  from ISO 8601.** The schema carries `format: date`/`time`/`date-time`, but a
  model may still send another format; the dispatcher answers
  `{:invalid_argument, {name, {:invalid_date, value}}}` and the model can retry.
  Declare `String.t()` if you
  want the raw string.
- **String arguments must be valid UTF-8.** JSON strings are Unicode; invalid
  bytes from a provider or direct caller become
  `{:invalid_argument, {name, {:invalid_utf8, value}}}`, not an exception. This
  applies to `String.t()`, `binary()`, `bitstring()`, patterns, `charlist()`,
  `char()`, atoms, enums and keyword keys.
- **Wire shapes are restored before dispatch.** `%{a: integer()}` arrives with
  atom keys at every declared level, `keyword(t)` as a keyword list,
  `charlist()` as a charlist, `char()` as a codepoint, tuples as Erlang tuples,
  and `1.0` as `1`. Open maps and `%{k() => v}` keep the string keys JSON gives
  them. `keyword/1` keys must already exist as atoms in the VM, like `atom()`:
  an unknown key is `{:unknown_atom, key}`.
- **Bare `struct()` is not reconstructed.** It is emitted as an open object and
  the function receives a plain map. A concrete `Mod.t()` is rebuilt into the
  struct, unless a type provider claims it first.
- **A struct type is a closed object.** Only its declared fields are accepted;
  an unknown key is `{:unknown_keys, keys}`. A provider overrides this when a
  struct should be sent as a scalar.
- **Recursive parameters use `$defs`.** Strict mode renders the definitions
  with the same rules as nested objects, so the schema stays valid for both
  providers.
- **Do not use a bare `atom()`.** The schema allows any string while the
  dispatcher only accepts atoms that already exist in the VM. Enumerate:
  `:red | :green`.
- **Open objects cannot be expressed with `strict: true`.** `map()`, `keyword(t)`
  and `%{k() => v}` are all objects with free keys; strict mode closes every
  object with `additionalProperties: false`, so the model can only send `{}`.
  The build warns for those parameters (and for `term()`, which has no type at
  all). Tuples lose their element types in strict mode (`prefixItems` is
  rejected) and keep only `minItems`/`maxItems`; the build warns too. Defaults
  are dropped in strict mode, because `default` is rejected. For a
  non-nullable optional value, `null` means "use the default"; for a nullable
  value it is passed through as `nil`.
- **Fine-tuned models accept less in strict mode.** Plain `strict: true` keeps
  `pattern`, the `format` values and numeric/array bounds; fine-tuned models
  reject those keywords and refuse the schema. Use `strict: :fine_tuned`
  (`--fine-tuned`) to drop them while keeping the strict shape.
- **Tool names are function names; there is no namespace.** When you concatenate
  tools from several modules, keep the names unique and route back to the right
  module. OpenAI and Anthropic require `^[a-zA-Z0-9_-]{1,64}$`; Gemini accepts
  longer names and dots/colons, but the library keeps the stricter pattern so
  one name works everywhere. A function named `find?` warns. Two arities of one function share a name; only the first is
  exposed, with a warning.
- **`use ToolCall` only accepts `:types`.** `use ToolCall, emit: [...]` raises; the
  precompiled OpenAI/Anthropic variants are always rendered; MCP and Gemini
  render on demand.
- **`@tool_param` needs `fun:`**:
  `@tool_param %{fun: :transfer, name: "user_id", wire: :string_integer}`.
  Large integers travel as decimal strings; see
  [`number-handling.md`](number-handling.md).
- **Deeply nested `@type` hierarchies are inlined up to a budget** (100
  inlinings). Past that the rest of the type is treated as `{}` and the build
  warns; flatten the hierarchy or enumerate the fields.
- **Result validation is opt-in and does not encode.** `run/4` with
  `validate_result: true` checks the raw return value against the `@spec`; the
  result is still returned as a plain term and must be JSON-encodable by the
  caller.
- **`run/3` uses module-level timeout/approval/audit policies.** With no
  module-level policies it has no timeout and runs on the fast path; configure
  `use ToolCall, timeout: ...` or use `run/4` for a per-call timeout. A tool
  that can hang without either should still be wrapped by the caller.
