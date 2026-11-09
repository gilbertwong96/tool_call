# Roadmap

The `0.2`, `0.3` and `0.4` labels are planned minor releases. They are not the
current version, fixed dates, or compatibility promises. The current line is
`0.1.0`; the stages group work by capability.

## 0.1 — current

Compile-time derivation from `@spec`, `@doc` and local types, typedoc fallback
descriptions, OpenAI and Anthropic emitters, custom type providers, coercion,
and the runtime dispatcher.

## 0.2 — type coverage

- Recursive types with `$ref` / `$defs`. Recursive local type references
  currently stop at the first re-entry and render as `{}`.
- Struct field extraction. Concrete structs should expose their fields and
  `@enforce_keys` should drive required fields instead of the current open
  object representation.
- Keep the existing local-type inlining budget and warning path for
  non-recursive expansion.

## 0.3 — output and integrations

- Result encoding: bring the `@spec` return type into the IR and use it for
  result validation/encoding. Return values are currently passed through
  without checking.
- MCP `emit/3` target. `mix tool_call.export --format mcp` already exists, but
  `ToolCall.emit(module, :mcp)` does not.
- Gemini `emit/3` target.
- Streaming helpers for aggregating `tool_calls` deltas. The current runtime
  operates on complete tool calls.

## 0.4 — runtime governance

- Approval / human-in-the-loop hooks.
- Per-tool timeouts. Callers currently have to wrap `ToolCall.run/3` in their
  own timeout.
- Audit log for dispatches.

## Later / not scheduled

These are useful additions without a target release yet:

- Additional built-in type providers such as `Decimal`, `URI`, `MapSet`,
  `Range` and `Regex`.
- Nested or remote typedoc inheritance if a description-composition model is
  chosen.

## Design boundaries

The limits that are intentional rather than planned are documented in
[`design.md`](design.md#design-boundaries).
