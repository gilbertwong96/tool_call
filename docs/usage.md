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
          {:ok, %{city: String.t(), days: pos_integer(), temp: float()}} | {:error, String.t()}
  def get_weather(city, days \\ 3), do: {:ok, %{city: city, days: days, temp: 21.5}}
end
```

Everything else is derived. What the library reads:

| You write | It reads |
|---|---|
| `@spec f(city :: String.t())` | parameter name `city` and its type. Without `city ::` the name falls back to the head variable (or `argN`) and a warning is printed; a bare type variable in a `when` constraint counts as unnamed |
| `def f(city, days \\ 3)` | `days` is optional, `3` is emitted as `default` |
| first `@doc` paragraph | tool `description` |
| `* name - text` under `## Parameters` | per-parameter `description` (indented continuation lines are joined; nested bullets and other shapes are ignored) |
| `@doc false` | the function is not a tool |
| no `@spec` | the function is skipped with a warning |
| `@type` in the same module | inlined; `Other.t()` from another module stays `{}` |
| a duplicate name, e.g. `f(city :: String.t(), city :: integer())` | the second becomes `city_2`, with a warning |
| `_ :: String.t()` | the head variable name, or `argN` if that is `_` too |

## 2. Emit a schema

```elixir
ToolCall.emit(MyApp.Tools.Weather, :openai)
ToolCall.emit(MyApp.Tools.Weather, :openai, strict: true)
ToolCall.emit(MyApp.Tools.Weather, :anthropic)

# several modules: concatenate the lists
tools = ToolCall.emit(A, :openai, strict: true) ++ ToolCall.emit(B, :openai, strict: true)
```

`strict: true` adds `"strict" => true`, makes every property required (nested
objects included), widens optional values to `["T", "null"]` and closes every
object. The dispatcher treats an explicit `null` for an optional argument or
field as absent, so a model that follows the strict schema is not rejected.

### When it happens

Everything is compile time. Inside `@before_compile` the library derives the IR
and renders the three supported variants — `{:openai, false}`,
`{:openai, true}` and `{:anthropic, false}` — into literals stored in
`__schemas__/0`. `ToolCall.emit/3` on a module is a map lookup, so `strict` may
be a runtime boolean and there is nothing to cache.

Measured on a 20-tool module: `emit/3` costs about 0.2 µs, a fresh render costs
about 47 µs, and the embedded schemas add roughly 35 KB to the beam and 9 ms to
compilation.

That is also why releases work: `mix release` strips the `Docs` and `Dbgi`
chunks, so Code.Typespec.fetch_specs/1 and `Code.fetch_docs/1` fail on the
compiled beam, and this library never calls them. See
[`pitfalls.md`](pitfalls.md).

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

## 5. Export the schemas

```sh
mix tool_call.export                              # OpenAI function objects
mix tool_call.export --format anthropic           # Anthropic tool definitions
mix tool_call.export --format mcp --out priv/tools.json
mix tool_call.export --strict
```

`--format` is `openai` (default), `anthropic` or `mcp`; `--strict` renders the
strict subset for OpenAI and MCP; `--app` discovers another application. Without
module arguments every module in the app that exports `__tools__/0` is included.
The output indents two spaces, sorts object keys and modules, and keeps
declaration order inside a module, so a committed file stays stable across runs.

Formatting uses `json:format/1`, so this task needs Erlang/OTP 27.1+; the rest of
the library still runs on older OTP. The formatter is OTP's: the same OTP version
reproduces the file, while an upgrade can reflow it without changing the JSON.
Tool names outside `^[a-zA-Z0-9_-]{1,64}$` are refused.

The task uses Elixir's built-in `JSON`, so the library itself still never depends
on a JSON encoder. When the request is built somewhere else, `ToolCall.describe/2`
returns `%{module, name, description, parameters}` for every tool — the same data
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
| `%{"b" => 2}` on `def f(a \\ 1, b \\ 2)` | `{:error, {:argument_gap, "a", ["b"]}}` — Elixir cannot pass a later argument past a skipped one, so the value is reported instead of dropped |
| `%{"city" => "Oslo", "days" => 1.5}` | `{:error, {:invalid_argument, {"days", {:expected_integer, 1.5}}}}` |
| `%{"city" => "Oslo", "days" => nil}` | `{:ok, ...}` — null for an optional argument means "use the default" |
| `[1, 2]` instead of a map | `{:error, {:invalid_arguments, [1, 2]}}` |
| a raising function | `{:error, {:raised, "..."}}` |

The full error list is in the [README](../README.md#errors).

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
- **`Decimal.t()` arrives as a decimal string.** JSON has no decimal type, and
  a JSON number is a binary float, so the schema constrains the value with a
  decimal `pattern` and the function receives that string. Use
  `Decimal.new(value)` if you need the struct; no `decimal` dependency is
  imposed on you.
- **Wire shapes are restored before dispatch.** `%{a: integer()}` arrives with
  atom keys at every declared level, `keyword(t)` as a keyword list,
  `charlist()` as a charlist, and `1.0` as `1`. Open maps and `%{k() => v}` keep
  the string keys JSON gives them. `keyword/1` keys must already exist as atoms
  in the VM, like `atom()`: an unknown key is `{:unknown_atom, key}`.
- **Do not use a bare `atom()`.** The schema allows any string while the
  dispatcher only accepts atoms that already exist in the VM. Enumerate:
  `:red | :green`.
- **Open objects cannot be expressed with `strict: true`.** `map()`, `keyword(t)`
  and `%{k() => v}` are all objects with free keys; strict mode closes every
  object with `additionalProperties: false`, so the model can only send `{}`.
  The build warns for those parameters (and for `term()`, which has no type at
  all). Tuples lose their element types in strict mode (`prefixItems` is
  rejected) and keep only `minItems`/`maxItems`; the build warns too. Defaults
  are dropped in strict mode, because `default` is rejected; send `null` and the
  dispatcher falls back to the default.
- **Tool names are function names; there is no namespace.** When you concatenate
  tools from several modules, keep the names unique and route back to the right
  module. Both providers require `^[a-zA-Z0-9_-]{1,64}$`, so a function named
  `find?` warns. Two arities of one function share a name; only the first is
  exposed, with a warning.
- **`use ToolCall` takes no options.** `use ToolCall, emit: [...]` raises; the
  three provider variants are always rendered.
- **`@tool_param` needs `fun:`**:
  `@tool_param %{fun: :transfer, name: "user_id", wire: :string_integer}`.
  Large integers travel as decimal strings; see
  [`number-handling.md`](number-handling.md).
- **Deeply nested `@type` hierarchies are inlined up to a budget** (100
  inlinings). Past that the rest of the type is treated as `{}` and the build
  warns; flatten the hierarchy or enumerate the fields.
- **`run/3` has no timeout.** A tool that can hang should be wrapped in
  `Task.async/1` + `Task.yield/2` by the caller.
