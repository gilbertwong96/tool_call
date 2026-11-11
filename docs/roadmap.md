# Roadmap

The `0.2`, `0.3` and `0.4` labels are planned minor releases. They are not
fixed dates or compatibility promises. The published line is `0.1.0`; `0.2` is
implemented and awaiting a release. The stages group work by capability.

## 0.1 — published

Compile-time derivation from `@spec`, `@doc` and local types, typedoc fallback
descriptions, OpenAI and Anthropic emitters, custom type providers, coercion,
and the runtime dispatcher.

## 0.2 — type coverage (implemented, unreleased)

- Recursive local types emit one `$defs` entry and a `$ref` at every
  occurrence, including the parameter. Cyclicity is decided statically, and
  two bounds keep a parameterized cycle finite.
- Concrete structs expose their fields as a closed object, with field types
  from the public `@type t` and `required` from `@enforce_keys`; dispatch
  rebuilds the struct. `@opaque` types are not extracted.
- Non-recursive local types keep the existing inlining budget and warning
  path.

## 0.3 — output and integrations

All planned items are implemented and awaiting a release.

- Result validation: done, as validation only. The `@spec` return type is in
  the IR and `run/4` validates the raw return value when opted in. Value → JSON
  encoding stays with the caller.
- MCP `emit/3` target: done. `ToolCall.emit/3` renders `{name, description,
  inputSchema}` on demand, and `mix tool_call.export --format mcp` uses it.
- Gemini `emit/3` target: done. `ToolCall.emit(module, :gemini)` renders
  `{name, description, parameters}` declarations, and
  `mix tool_call.export --format gemini` wraps them in a `tools` value. The
  schema is Gemini's OpenAPI subset, not JSON Schema.
- Streaming helpers: done. `ToolCall.Stream.aggregate/2` (or `new/1` +
  `feed/2` + `finish/1`) folds OpenAI Chat Completions, Anthropic Messages and
  Gemini `functionCall` chunks into complete calls for `run/3`.

## 0.4 — runtime governance

All planned items are implemented and awaiting a release.

- Approval / human-in-the-loop hooks: done as a policy hook
  (`use ToolCall, approval: ...`, `run/4 approval:`). A required decision returns
  a serializable `ToolCall.Approval.Request`; persistence, notification and
  resume belong to the application or agent runtime.
- Per-invocation timeouts: done as an opt-in per-invocation cap. `ToolCall.run/4`
  accepts `timeout:`/`task_supervisor:`, `Runner.execute/2` takes the same
  override, and `use ToolCall, timeout: ...` sets a default or a
  `ToolCall.Timeout` policy (which can inspect the tool). The overall run
  deadline stays with the caller or agent framework.
- Audit log for dispatches: done as a hook. `use ToolCall, audit: ...` or
  `run/4 audit:` receives one `%ToolCall.Audit.Entry{}` per attempt, including
  resolve/execute policy exceptions; persistence, redaction and retention stay
  with the application.
- Startup policy validation: done as `ToolCall.validate_policies!/1` plus the
  one-shot `ToolCall.PolicyValidation` supervision child. It checks module-level
  timeout, approval and audit policies before dispatch.

## Later / not scheduled

These are useful additions without a target release yet:

- Additional built-in type providers such as `Decimal`, `URI`, `Range` and
  `Version`.
- Nested or remote typedoc inheritance if a description-composition model is
  chosen.

## Design boundaries

The limits that are intentional rather than planned are documented in
[`design.md`](design.md#design-boundaries).
