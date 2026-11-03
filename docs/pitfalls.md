# Pitfalls

Everything below was measured on Elixir 1.20.4 / OTP 29 before the library was
written. Each entry lists the symptom, the evidence, and what this library does
about it.

Severity: **fatal** means "the library silently produces wrong output";
**important** means "compiles but hurts"; **long tail** means "unsupported on
purpose".

## 1. Runtime reflection dies in releases — fatal

**Symptom.** Works in `mix test`, breaks in production.

```elixir
:beam_lib.strip(beam)
# chunks left: Line, Type, AtU8, Code, StrT, ImpT, ExpT, LitT

Code.Typespec.fetch_specs(M)  #=> :error
Code.Typespec.fetch_types(M)  #=> :error
Code.fetch_docs(M)            #=> {:error, :chunk_not_found}
```

`mix release` strips `Docs` and `Dbgi` by default, and `--no-debug-info` removes
them for plain builds. A library that reflects at runtime is broken exactly in
the environment where it matters.

**Handled.** Everything is derived in `@before_compile`. No Code.Typespec call
exists outside of docs.

## 2. `@spec` has no parameter names — fatal

**Symptom.** The schema has `arg1`, `arg2`, and the model cannot use it.

```elixir
@spec get_weather(String.t()) :: ...
#=> {:get_weather, _, [{{:., _, [String, :t]}, _, []}]}   # no name anywhere
```

**Evidence.** Annotated arguments do keep their name:

```elixir
@spec get_weather(city :: String.t()) :: ...
#=> {:get_weather, _, [{:"::", _, [{:city, _, nil}, {{:., _, [String, :t]}, _, []}]}]}
```

**Handled.** Names come from `ann_type`. Missing names produce a compile-time
warning and an `argN` fallback.

## 3. `@spec` is an accumulative attribute — important

**Symptom.** Wrong spec attached to the wrong function.

```elixir
Module.get_attribute(mod, :spec)
#=> [ {:spec, <get_weather spec>, {mod, {50, 1}}},
#     {:spec, <two_specs spec>,   {mod, {59, 1}}}, ... ]
```

At any `@on_definition` call the attribute already contains every earlier
function's spec.

**Handled.** `ToolCall.Builder.find_spec/3` filters by `{name, arity}` and warns
when a function has several specs (overloads cannot be one JSON Schema).

## 4. Aliases are not expanded in the attribute — important

**Symptom.** `alias MyApp.Money` turns `Money.t()` into `:any`, so the parameter
silently becomes unconstrained.

```elixir
{{:., _, [{:__aliases__, _, [:String]}, :t]}, _, []}
```

**Handled.** `Macro.prewalk/2` + `Macro.expand/2` against the `@before_compile`
environment, which still carries the aliases.

## 5. `@typedoc` is consumed before `@before_compile` — important

**Symptom.** Type-level documentation never reaches the schema.

```elixir
defmacro __before_compile__(env) do
  Module.get_attribute(env.module, :typedoc)  #=> nil
end
```

`@typedoc` is consumed by the following `@type`, so it is gone by the time the
macro runs. `Code.fetch_docs/1` cannot be used as a workaround either: it only
accepts a module or a path, and `Code.fetch_docs(beam_binary)` raises
`UnicodeConversionError` because the binary is treated as a path.
``Code.Typespec.fetch_specs(binary)`` *does* accept a binary.

**Not handled.** Type descriptions must currently come from `@doc` bullets or
`@tool_param`.

## 6. `@doc` is single-valued and consumed immediately — important

**Symptom.** The last function's doc is attached to every tool, or `nil`.

**Handled.** Captured in `@on_definition`, which runs before the attribute is
reset. `@doc false` is used as the "not a tool" switch.

## 7. JSON Schema `integer` accepts `1.0` — important

**Symptom.** `ArgumentError` or a wrong branch in a function guarded by
`is_integer/1`.

```elixir
Jason.decode!("1.0")               #=> 1.0
is_integer(Jason.decode!("1.0"))  #=> false
```

Draft 2020-12 defines `integer` as a number with a zero fractional part, so the
schema considers `1.0` valid.

**Handled.** `ToolCall.Coerce` truncates integral floats and rejects fractional
ones.

## 8. `float()` parameters can receive integers — important

**Symptom.** `def f(x) when is_float(x)` crashes on `2`.

`{"type":"number"}` accepts `2`, and `Jason.decode!("2")` returns the integer
`2`, not `2.0`.

**Handled.** `ToolCall.Coerce` widens integers to floats.

## 9. Numbers that JSON allows but Elixir cannot represent — important

**Symptom.** The schema is valid, the decoder raises.

```elixir
Jason.decode!("1e309")  #=> ** (Jason.DecodeError)
JSON.decode!("1e309")   #=> ** (JSON.DecodeError)
```

Erlang floats cannot be infinite, so `{"type":"number"}` admits inputs that
cannot be decoded at all. Validation never runs.

**Not handled** (nothing can be): documented, and the guidance is to keep
`format: "double"`-style promises out of the schema.

## 10. Big integers lose precision outside Elixir — fatal

**Symptom.** `9007199254740993` arrives as `9007199254740992` somewhere
downstream.

| Layer | Precision |
|---|---|
| JSON grammar | unbounded |
| Elixir `integer` | arbitrary |
| `Jason` / `JSON` | lossless (`2^80` round-trips exactly) |
| JS `Number`, Go `float64` | `2^53 - 1` |
| Provider-side parsing | unknown, assume the worst |

**Handled.** `wire: :string_integer` emits `{"type":"string","pattern":"^-?\\d+$"}`
and the dispatcher parses it back. Default remains `integer`; adding a `2^53`
bound by default would reject values the function can genuinely handle. See
[`number-handling.md`](number-handling.md).

## 11. Defaults live in the head, not in the spec — important

**Symptom.** `required` is wrong, or the arity never matches.

```elixir
def __on_definition__(env, :def, name, args, _guards, _body) do
  args
  #=> [{:city, _, nil}, {:\\, _, [{:days, _, nil}, 3]}]
end
```

`@spec f(A, B)` still has arity 2 even though callers may pass one argument.
Defaults can appear before required arguments (`def f(a \\ 1, b)`), so the
runner cannot assume they are trailing. It allows the reduced-arity calls
Elixir can actually position — all required arguments plus a prefix of the
optional arguments — and reports an `:argument_gap` only when a later optional
would be shifted into the wrong slot.

**Handled.** The runner builds exactly that argument list before `apply/3`.

## 12. `@on_definition` fires for private functions and per clause — important

**Symptom.** Private helpers leak into the tool list, or every clause produces a
duplicate tool.

**Handled.** `kind == :def` filter and `Enum.uniq_by({name, arity})`.

## 13. Struct types arrive pre-inlined, with `__struct__` — long tail

```elixir
@spec f() :: %URI{}
#=> {:type, _, :union, [{:type, _, :map, [__struct__: URI, authority: term(), ...]}, ...]}
```

The expansion includes `__struct__` and marks every field required, regardless
of `@enforce_keys`.

**Not handled, and not yet reachable.** The library does not expand remote types,
so `URI.t()` is `{}` today; the inline form above only matters once remote
expansion exists. Stripping `__struct__` and reading `__enforce_keys__/0` is on
the roadmap.

## 14. Local types are resolved, but recursion has to stop somewhere — long tail

`@type tree :: {:node, tree(), tree()}` cannot be inlined without bound.
`@typep` definitions are also resolvable (they live in their own `:typep`
attribute), so "expand everything" has to decide what may leak.

**Handled.** `@type`, `@typep` and `@opaque` are inlined with parameter
substitution. The first re-entry of a name inside its own expansion is left
unresolved and degrades to `{}`; `$ref`/`$defs` for a truthful recursive schema
is still on the roadmap.

Non-recursive hierarchies explode too: `@type t0 :: {t1(), t1()}` with every
level doubling is `2^depth`. Measured: depth 16 took 16 s, depth 18 took 83 s
to compile. A budget of 100 inlinings per type caps it — depth 18 is 28 ms now
— and hitting the budget degrades the rest of the type to `{}` with a
compile-time warning.

Private types are resolved rather than hidden: a tool signature that uses a
private alias would otherwise show the model `{}`, which is strictly less useful
than the fields the author wrote down.

## 15. Compile-time cost and error ergonomics — long tail

Every `def` triggers a callback, and every warning is formatted by hand. The
library keeps the callback cheap (attribute append only) and does all the work
once in `@before_compile`; warnings point at the `def` line via `IO.warn/2` with
`file:`/`line:`.

Two things cost more than the callback itself, both measured on Elixir 1.20.4 /
OTP 29 with a 20-tool module:

| | 5 tools | 20 tools |
|---|---|---|
| plain module | 7.3 ms | 12.2 ms |
| `use ToolCall` (IR + three schemas) | 14.6 ms | 43.0 ms |

The embedded schemas add ~35 KB to the beam (literal chunk plus the compiler's
check chunk) and ~9 ms of the compile time; the rest is the IR itself and
`Macro.escape/1`. In exchange, `emit/3` on a module is a map lookup: 0.2 µs
against 47 µs for a fresh render.

## 16. `@spec` names are documentation, not syntax — important

The compiler does not enforce unique or useful parameter names, so both of these
compile without a single warning:

```elixir
@spec f(city :: String.t(), city :: integer()) :: String.t()
@spec g(_ :: String.t(), _ :: integer()) :: String.t()
```

For Elixir the two parameters are positional; the names only exist for humans.
A schema is different: property names are the contract, `required` is a list of
names, and the dispatcher looks values up by name. Shipping the AST names as-is
produces a `required` list with `"city"` twice and two parameters that can never
both be satisfied. The library renames duplicates (`city_2`) and replaces `_`
with the head variable or `arg1`, warning each time.

The same trap exists at the function level: `f/1` and `f/2` with the same name
produce two tools with one name. Providers reject duplicate names in the tool
list, so the second is dropped with a warning.

## 17. `@doc` metadata never reaches the `:doc` attribute — long tail

Measuring `Module.get_attribute(module, :doc)` from `@on_definition`, which is
where the library reads docs:

```elixir
@doc deprecated: "use bar/1"     #=> nil
@doc "The text."
@doc since: "1.2.0"              #=> {line, "The text."}
@doc since: "1.2.0"
@doc "The text."                 #=> {line, "The text."}
```

Metadata-only `@doc` never touches the `:doc` attribute: `Code.fetch_docs/1`
shows it as `%{deprecated: ...}` with the text set to `:none`, and the metadata
only exists in the `Docs` chunk, which releases strip. A tool declared that way
has no description and silently falls back to its function name, so write text
as well if the model is supposed to see one.

## 18. `@on_definition` accumulates — useful

Unlike `@doc`, `@on_definition` is an accumulating attribute:

```elixir
defmodule MyApp.Tools do
  @on_definition MyApp.Introspection   # still runs
  use ToolCall                        # appends, does not replace
end
```

`use ToolCall` therefore does not silently disable instrumentation or another
library's definition hook — both callbacks fire, including for the generated
`__tools__/0` and friends. Worth knowing before you assume the last `use` wins.

## 19. The strict subset is narrower than JSON Schema — important

OpenAI's `strict: true` accepts a subset, and an unlisted keyword is a request
error, not a silent downgrade. The list below follows the structured-outputs
guide as quoted by `apcore`'s strict-mode detector (checked 2026-08; it moves):

| Supported | Rejected |
|---|---|
| `string`, `number`, `boolean`, `integer`, `object`, `array`, `enum`, `anyOf` (not at the root) | `allOf`, `not`, `oneOf`, `if`/`then`/`else`, `dependentRequired`, `dependentSchemas` |
| `pattern`, `format` (`date-time`, `time`, `date`, `duration`, `email`, `hostname`, `ipv4`, `ipv6`, `uuid`) | `minLength`, `maxLength` |
| `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf` | — |
| `minItems`, `maxItems` | `prefixItems`, `additionalItems`, `contains`, `minContains`, `maxContains`, `uniqueItems`, `unevaluatedItems` |
| `properties`, `required`, `additionalProperties: false` | `minProperties`, `maxProperties`, `patternProperties`, `propertyNames`, `unevaluatedProperties` |
| `$defs` / `$ref`, recursion to the root | — |

Two consequences the library has to handle: a tuple cannot keep its positions
(`prefixItems` is rejected, so the strict variant keeps the arity only) and a
default must be dropped (`default` is rejected; nullability carries the same
idea). `pattern` being supported is what makes `wire: :string_integer` and
`char()` usable in strict mode at all.

## Reproducing the measurements

```bash
mkdir probe && cd probe
cat > m.ex <<'EOF'
defmodule M do
  @spec f(x :: String.t()) :: {:ok, map()} | {:error, atom}
  def f(_), do: :ok
end
EOF
elixirc -o ebin m.ex
:beam_lib.strip(~c"ebin/Elixir.M.beam")
```

Then, from an `elixir -pa ebin -e '...'`:

```elixir
Code.Typespec.fetch_specs(M)   # after strip: :error
Code.fetch_docs(M)             # after strip: {:error, :chunk_not_found}
```
