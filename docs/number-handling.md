# Numbers

`integer()` in Elixir is arbitrary precision. JSON the grammar is too. Nothing
else in the path necessarily is. This note records where precision is lost and
what the library does about it.

## Four different limits

| Layer | Limit | Lossless? |
|---|---|---|
| JSON grammar (RFC 8259) | none | — |
| Erlang/Elixir `integer` | none (bignum) | yes |
| `Jason` / `JSON` | none | yes — measured: `2^80` round-trips exactly |
| JSON Schema `integer` | none | semantic only |
| JS `Number`, Go `float64` | `2^53 - 1` for integers | **no** |
| Provider-side parsing | undocumented | **assume no** |

So the library's own encode/decode path is safe:

```elixir
Jason.encode!(Integer.pow(2, 80))   #=> "1208925819614629174706176"
JSON.encode!(Integer.pow(2, 80))    #=> "1208925819614629174706176"
```

The loss happens when the value crosses into someone else's parser:

```elixir
9007199254740993  # 2^53 + 1
# as double: 9007199254740992
```

## Four failure modes

1. **Silent truncation downstream.** The function receives the exact value; a JS
   client, a log pipeline or another service does not.
2. **Schema says `integer`, Elixir says "not an integer".** `{"type":"integer"}`
   accepts `1.0` (draft 2020-12); `Jason.decode!("1.0")` returns a float.
3. **Schema says `number`, the function gets an integer.** `{"type":"number"}`
   accepts `2`; `is_float(2)` is false.
4. **Schema-valid but undecodable.** `1e309` is a legal JSON number and an
   illegal Erlang float: `Jason.decode!("1e309")` raises before any validation
   can run.

## Two orthogonal decisions

`@spec` describes the value domain. `@tool_param` describes the wire format.
They are not the same question, so they are not the same annotation.

```elixir
@tool_param %{fun: :transfer, name: "user_id", wire: :string_integer,
              description: "Snowflake id"}
@spec transfer(user_id :: integer(), amount_cents :: pos_integer()) :: ...
```

| Elixir | Schema | Wire |
|---|---|---|
| `integer()` | `{"type":"integer"}` | `:number` (default) |
| `integer()` + `wire: :string_integer` | `{"type":"string","pattern":"^-?\\d+$"}` | `:string_integer` |
| `pos_integer()` | `+ "minimum": 1` | `:number` |
| `1..100`, `-90..90` | `+ "minimum"/"maximum"` | `:number` |
| `float()` / `number()` | `{"type":"number"}` | `:number` |

Why no default `2^53 - 1` bound: a tool backed by `integer()` genuinely accepts
larger values, and clamping the schema would make the model refuse identifiers
the function handles fine. Cross-language safety is therefore opt-in.

Why `string_integer` and not `format: "int64"`: `format` is an annotation,
ignored by most validators and by constrained decoding. `pattern` is not.

`string_integer` only applies to an `integer()` parameter. On any other type the
build ignores it with a warning, and an integer default is rendered as a string
(`42` → `"42"`), because that is what the schema says the model should send.

The string form carries only the pattern. Integer bounds (`pos_integer()`,
`1..100`) are still enforced at dispatch but cannot be expressed on a string, so
the schema is looser than the runtime for bounded integers.

The dispatcher also accepts the number form (a JSON integer) for a
`:string_integer` parameter. That is a convenience for direct callers; the schema
still asks the model for a string.

## The coercion pass

Schemas and Elixir disagree at the boundary, so `ToolCall.Coerce` runs before
the function is applied:

| Incoming | `integer()` | `float()` | `number()` |
|---|---|---|---|
| `1` | `{:ok, 1}` | `{:ok, 1.0}` | `{:ok, 1}` |
| `1.0` | `{:ok, 1}` | `{:ok, 1.0}` | `{:ok, 1.0}` |
| `1.5` | error | `{:ok, 1.5}` | `{:ok, 1.5}` |
| `"42"` | error (unless `wire: :string_integer`) | error | error |
| `nil` | ok only if nullable | ok only if nullable | ok only if nullable |

Bounds are enforced here too, so `pos_integer()` rejects `0` even if the model
ignores `minimum`.

## Guidance for tool authors

- **Bounded integers:** put the bound in the spec (`1..7`), not only in prose.
  It is the only constraint that shows up in the schema.
- **Identifiers and hashes:** `wire: :string_integer`.
- **Money:** integer minor units, documented in the description; never
  `float()`.
- **Long numbers are hard for models.** An 18-digit id is frequently off by one
  digit, and `minimum`/`maximum` are not enforced during generation. `pattern`
  and `enum` are.
