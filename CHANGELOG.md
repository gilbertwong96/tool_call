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

### Changed

- **Compatibility break:** a struct type with a public `@type t` is now a closed
  object that dispatch rebuilds, where 0.1 emitted `{}` and passed any value.
  This covers scalar wrappers such as `Decimal.t()` and `Range.t()`; add a
  `ToolCall.TypeProvider` to keep the old permissive shape or to send the
  value as a scalar. `@opaque` types are unchanged.

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
