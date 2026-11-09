# Changelog

## Unreleased

### Added

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

### Changed

- **Compatibility break:** a struct type with a public `@type t` is now a closed
  object that dispatch rebuilds, where 0.1 emitted `{}` and passed any value.
  This covers scalar wrappers such as `Decimal.t()`, `URI.t()` and `Range.t()`;
  add a `ToolCall.TypeProvider` to keep the old permissive shape or to send the
  value as a scalar. `MapSet` and `Regex` have built-in providers, and
  `@opaque` types are unchanged.

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
