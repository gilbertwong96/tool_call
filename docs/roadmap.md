# Roadmap

`0.2.0` is released: tag `v0.2.0`, GitHub release, and the Hex package. The
completed feature set is recorded in [`CHANGELOG.md`](../CHANGELOG.md) and the
usage guide. This file tracks only work that is not implemented yet.

## Waiting on the compiler

These depend on Elixir shipping native type signatures or typed structs. The
internal seams exist, but the syntax is not stable enough to parse.

- **Native signature source.** `ToolCall.TypeSource` accepts another source that
  returns `ToolCall.TypeSource.Declaration`. Such a source would emit
  `ToolCall.TypeExpr` directly instead of typespec AST, and no builder, IR, or
  emitter change is needed.
- **Typed struct fields.** `ToolCall.Structs` reads `@type t` today through
  `ToolCall.LegacyTypespec`. Once typed structs carry field types and field docs,
  that module becomes the replacement point, and struct properties gain
  descriptions.
- **`if_set` / `not_set`.** Optional versus nullable keys become distinguishable
  at the type level, which changes `required` lists rather than the wire subset.

## Deferred by choice

These are implemented partially, or deliberately left for later.

- **Declaration payload as `ToolCall.TypeExpr`.** `Declaration.params[].type` and
  `Declaration.return` still carry typespec AST. Moving them to `TypeExpr`
  requires either `$defs` naming that no longer derives from the AST term hash,
  or a dual representation for `Typedoc` provenance. `TypeExpr` already sits at
  the mapping boundary, so this is an internal storage decision, not a
  capability gap.
- **Set-theoretic projection.** `TypeExpr` has `:intersection` and `:negation`
  nodes, and `TypeExpr.Compiler` lowers both to `:unsupported`. Implementing
  them means deciding what an "exact" intersection is and how a negation reaches
  JSON Schema; neither is silently approximated to `anyOf` today. See
  [`projection.md`](projection.md).
- **Diagnostic severity.** `ToolCall.Diagnostic` carries `:warning | :error`, but
  every current producer emits warnings and the builder renders both the same
  way. Severity becomes meaningful when a source can fail a compile rather than
  skip a tool.

## Later / not scheduled

- Nested or remote typedoc inheritance if a description-composition model is
  chosen.

## Design boundaries

The limits that are intentional rather than planned are documented in
[`design.md`](design.md#design-boundaries).
