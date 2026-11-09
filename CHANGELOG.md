# Changelog

## Unreleased

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
