# Changelog

## Unreleased

### Added

- Derive a tool's `@spec` return type into `%ToolCall.IR.Tool{result: ...}`,
  sharing the tool's `$defs`. `ToolCall.run/4` with `validate_result: true`
  validates the raw return value against it and answers
  `{:error, {:invalid_result, reason}}` on a mismatch. Opt-in; `run/3` never
  validates.
- `ToolCall.TypeProvider` gains an optional `validate(type, value, defs)` for
  the value domain; the built-ins cover the calendar types, `Keyword` and
  `MapSet` (including element types) and `Regex`. An improper list or an exotic
  map key in a result is `{:invalid_result, ...}`, not a raise.

- `ToolCall.emit/3` supports `:mcp`, returning `{name, description, inputSchema}`
  tool objects for an MCP `tools/list` result. MCP renders on demand from the
  tool IR; `strict: true` renders the closed schema subset without a flag.

- `ToolCall.emit/3` supports `:gemini`, returning `{name, description,
  parameters}` declarations for `functionDeclarations`. The parameters object is
  Gemini's OpenAPI 3.0 subset: uppercase types, `nullable: true`, no
  `additionalProperties`, no `prefixItems`; non-string enums are dropped and a
  recursive `$ref` raises. `mix tool_call.export --format gemini` wraps them as
  `{"tools": [{"functionDeclarations": [...]}]}`.

- `ToolCall.Stream` aggregates streaming tool-call deltas: `aggregate/2` or
  `new/1` + `feed/2` + `finish/1` for OpenAI Chat Completions, Anthropic
  Messages and Gemini function calls. `arguments` is decoded; invalid JSON is
  `{:invalid_stream_arguments, {id, name, json}}` and a call without a name is
  `{:missing_name, id}`. This completes the planned `0.3` items.
- `strict: :fine_tuned` (and `mix tool_call.export --fine-tuned`) emits the OpenAI
  strict shape without `pattern`, `format`, numeric bounds or array bounds,
  which fine-tuned models reject. It renders on demand.
- A struct compiled without a typespec chunk (in memory or with
  `debug_info: false`) now falls back to parsing its source file for `@type t`
  (simple aliases, multi-aliases, enclosing-module aliases and `@typep` are
  expanded in declaration order); a module with no source warns
  "has no readable typespec" instead of degrading silently.
- `ToolCall.Runner.resolve/4` and `execute/2` split preparation from the side
  effect. `ToolCall.run/4` accepts `timeout:` and `task_supervisor:`, and
  `use ToolCall, timeout: ...` sets a default or a `ToolCall.Timeout` policy; a
  timeout answers `{:error, {:timeout, ms}}`, and `context:` reaches the policy.
  Timeouts are per invocation and a hard kill, not a cancellation.
- `ToolCall.Approval` adds a policy hook: `use ToolCall, approval: Policy` or
  `run/4 approval:`; `check/3` can approve, deny, or return a serializable
  pending request. No persistence or resume state machine is built in.
- `ToolCall.Audit` adds a dispatch audit hook: `use ToolCall, audit: Policy` or
  `run/4 audit:` receives one `Entry` per attempt (ok/error/raised/pending/
  denied/timeout/invalid arguments/unknown tool). It is fail-open and does not
  persist; redact the raw args in the hook.

- Recursive local types emit `$defs`/`$ref` instead of `{}`. Cyclicity is
  decided statically, so the parameter itself is a `$ref` and each type has one
  canonical body.
- Concrete struct types (`%Mod{}`, `Mod.t()`) expose their fields as a closed
  object, with field types from the public `@type t` and `required` from
  `@enforce_keys`. Dispatch reconstructs the struct and keeps `defstruct`
  defaults for omitted fields.
- Recursive struct types use the same `$defs`/`$ref` path.
- Built-in providers for `MapSet.t/0`, `MapSet.t/1` (an array of elements,
  rebuilt with `MapSet.new/1`) and `Regex.t/0` (its source string, compiled with
  `u` at dispatch), so a set or a regex no longer exposes its internal fields.
- A struct whose only type is `@type t/N`, or whose `t/0` is not a
  `%__MODULE__{}` literal, warns at compile time instead of silently untyping
  every field. An exception struct exposes its payload but not `__exception__`.
- `$defs` names for a parameterized instantiation carry a short signature
  (`tree_integer_40ca`), so adding a parameter never renames an existing entry.
- Compiling outside a Mix project no longer exits; the typedoc companion is
  skipped with a warning and the phase-one descriptions are used.
- `ToolCall.validate_policies!/1` validates the module-level timeout, approval
  and audit policies at startup, including their callback arities and valid
  module-level approval modes. One-off `run/4` options remain validated at the
  call site.

### Changed

- A struct defined in the same module as its tools is now extracted from the
  field map in the generated `__struct__/0`, with types from `@type t/0`, and
  `defstruct`'s `__struct__/0,1` no longer warn about a missing `@spec`.
- An enum value that is a boolean no longer accepts its string form (`"true"`);
  booleans are JSON literals, not atoms on the wire.
- `Address.t() | nil` keeps the null branch for a struct parameter and for
  result validation; the resolved struct object previously dropped `nullable`.
- A result type that cannot be validated — `term()`, an unknown remote type,
  `fun()`/`pid()`, an `@opaque` struct, or a budget-truncated type — now warns
  that `run/4` with `validate_result: true` accepts any value; the budget
  warning names the same consequence. A provider `validator` suppresses the
  warning because the value is checked.
- The result warning now walks the type and reports nested untyped paths:
  object fields, open-object values (`"*"`), array items (`"[]"`), tuple
  positions, union variants, struct fields and `$ref` bodies. A provider
  `validator` stops the walk at its subtree; a budget-truncated result keeps the
  single budget warning.
- The embedded IR drops AST `Type.source` values from parameters, the result and
  `$defs`, while keeping the string sub-kind atoms that dispatch and result
  validation read; this shrinks the beam.
- A provider `validator` that is not exported with arity 3 now raises with the
  provider and the remote type in the message, like the other provider IR
  errors.
- An explicit provider `validator` may live in a file compiled in parallel with
  the tool: the build waits for it with `Code.ensure_compiled?/1` instead of
  treating it as missing.
- `Mod.t(integer())` now resolves as a struct (the type arguments are not
  substituted), so a parameter keeps a callable tool and a result is validated
  as a struct; previously it degraded to `{}` and hid the tool.
- A struct whose `@type t` unions `nil` keeps its field types and is nullable
  wherever it is used; other unions still degrade to `{}`.
- A `@doc` bullet under `## Parameters` that names no parameter now warns with
  the offending name instead of being dropped silently.
- A `@doc` bullet under `## Options` documents the keys of a keyword argument;
  it is no longer reported as an unknown parameter and no longer names an
  unannotated parameter by position.
- An enum that mixes atoms with booleans or integers stringifies the atoms, so
  the schema term is JSON-encodable by any encoder.

- **A tool with an untyped argument is not exposed.** `term()`, `any()`, a
  remote type without a provider and an `@opaque` struct leave the argument
  undescribable, so the function is skipped with a compile-time warning instead
  of shipping a `{}` schema. Runtime IR may still use `:any`.

- **Compatibility break:** a struct type with a public `@type t` is now a closed
  object that dispatch rebuilds, where 0.1 emitted `{}` and passed any value.
  This covers scalar wrappers such as `Decimal.t()`, `URI.t()` and `Range.t()`;
  add a `ToolCall.TypeProvider` to keep the old permissive shape or to send the
  value as a scalar. `MapSet` and `Regex` have built-in providers, and
  `@opaque` types are unchanged.

### Fixed

- `ToolCall.Runner.resolve/4` now stores the module's `use ToolCall, timeout:`
  constant or policy instead of dropping it. `execute/2` evaluates the policy
  after approval with the validated raw argument map and context, so a pending
  or denied call does not run the policy; a policy exception returns
  `{:error, {:invalid_timeout, reason}}`.
- `run/4` honors `:task_supervisor` when the timeout comes from the module
  default, and `:infinity` with a supervisor now starts a supervised task. An
  unreachable or invalid supervisor answers `{:error, {:task_supervisor,
  reason}}` instead of exiting the caller.
- `execute/2` validates an explicit `:timeout` override before approval, so a
  pending/denied decision cannot hide an invalid timeout.
- `ToolCall.Call` stores the `:context` given to `resolve/4`, so `execute/2`
  passes it to the approval, timeout and audit hooks (an `execute/2` context
  still overrides it). The struct documents that it is a trusted resolve
  handoff, not data to deserialize from model output.
- Audit outcomes now come from the dispatch path, not from the final error
  tuple: a tool returning `{:error, {:timeout, ...}}` or
  `{:error, {:approval_denied, ...}}` is recorded as `:error`. Non-map
  arguments are audited as `:invalid_arguments`; policy exceptions, invalid
  timeout overrides and invalid runtime IR are audited as `:error` with
  `error: {:exception, message}` (a timeout policy error is returned as
  `{:invalid_timeout, term}`); `audit: nil` no longer constructs an entry.
- `ToolCall.run/4` uses the prepared-tool path for compiled modules instead of
  revalidating every tool on each option-carrying call.
- `Runner` validates its public option keys and rejects boolean/invalid
  approval or audit values before dispatch. Approval/audit options are checked
  for `check/3` / `record/1`; module-level policies are loaded on demand and
  checked when resolved. Module-level `approval: :granted` / `:denied` remains a
  valid mode.
- `Runner.execute/2` uses the call's stored audit policy when a dispatch
  exception is audited, not only the module or per-call audit option.
- `:crypto` is declared in `extra_applications`; audit and approval ids work in
  a release that contains only this library.
- An Anthropic stream whose initial `input` is not a map, and has no
  `input_json_delta` fragments, is now `:invalid_stream_arguments` instead of
  silently becoming `{}`.

## 0.1.0 - 2026-11-09

### Added

- Derive tool schemas from `@spec`, `@doc`, and `@typedoc` without a separate
  schema DSL.
- Emit OpenAI and Anthropic tool schemas, including OpenAI strict mode.
- Dispatch tool calls through `ToolCall.run/3` with required and unknown
  argument checks, coercion, and exception wrapping.
- Export schemas as JSON for OpenAI, Anthropic, and MCP with
  `mix tool_call.export`.
- Resolve custom application types through `ToolCall.TypeProvider`, including
  an optional `coerce/1` hook.
- Recover docs-visible `@type` metadata from a compile-time companion beam so
  releases keep typedoc descriptions.
- Support large integer arguments with the `string_integer` wire format.

### Changed

- Speed up scalar tool dispatch with generated per-tool runners, falling back
  to `ToolCall.Runner` for complex shapes.

### Compatibility

- Requires Elixir `~> 1.18` and Erlang/OTP 27.1 or newer.
