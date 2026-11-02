# Naming

Decision record for the package and top-level module name.

## Criteria

1. `use X` reads like a sentence in a module body.
2. `X` works as a namespace root (`X.Provider.OpenAI`, `X.Schema`, `X.Validate`).
3. It does not lock the library into "generate schema from typespec" — the
   dispatcher, coercion and emitters are half the value.
4. It is findable on Hex, which has no tags: name and description only.
5. It does not collide with the existing ecosystem.

Criterion 3 rules out `tool_spec`, `spec_tool`, `spec_to_tool`.
Criterion 5 rules out `agent_tool`, `toolbelt`, `anvil`, `chisel`.

## Availability (checked against hex.pm)

| Name | Status |
|---|---|
| `tool_call` | free |
| `toolwright` | free |
| `jig` | free |
| `tool_spec` | free |
| `agent_tool` | taken |
| `toolbelt` | taken |
| `anvil` | taken |
| `chisel` | taken |

The module name `ToolCall` appears in a few unpublished applications
(`deepfates/imp`, `z80dev/lemon`, `frontman-ai/frontman`). Those are internal
modules, not packages, so there is no namespace conflict — but it confirms the
name is the obvious one, which is both why it is memorable and why it was worth
claiming early.

## Decision

Package `tool_call`, module root `ToolCall`.

```elixir
use ToolCall
ToolCall.emit(MyApp.Tools.Weather, :openai, strict: true)
ToolCall.run(MyApp.Tools.Weather, :get_weather, %{"city" => "Oslo"})
```

`ToolCall` is the domain term every provider and MCP use (`tools/call`), it
survives a future move into MCP tool servers, and it says nothing it will later
have to contradict.

Rejected alternatives:

- **`toolwright`** — better brand, `use Toolwright` reads better, but nobody
  searching "elixir llm tool call" will find it, and it echoes Playwright.
- **`jig`** — the most Elixir-sounding option (Plug, Tesla, Finch, Oban), but
  meaningless at a glance; a fitting name for a library with users, not the
  first one.
- **`tool_spec`** — most precise for the current feature set and the most
  misleading six months from now.

Hex package names cannot be reserved, only published. If this is meant to be
public, publishing a `0.1.0-dev` early is the only way to hold the name.
