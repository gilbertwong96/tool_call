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

- **Set-theoretic projection beyond the exact cases.** `ToolCall.TypeExpr.Projection`
  lowers what JSON Schema can carry exactly: maps, tuples, integer ranges,
  literals, enums, identical refs and remotes, and string constraint narrowing.
  A bare complement or a disjoint-kind intersection still reports `:unsupported`
  and warns. Extending that means deciding on more set operations, not turning on
  something already written. See [`projection.md`](projection.md).
- **Diagnostic severity for shipped sources.** The builder fails the compile on
  an `:error` diagnostic and honours a diagnostic's own `@spec` position, but
  every shipped source still reports `:warning`; `:error` exists for sources that
  cannot skip a declaration.

## Later / not scheduled

- Nested or remote typedoc inheritance if a description-composition model is
  chosen.

## Design boundaries

The limits that are intentional rather than planned are documented in
[`design.md`](design.md#design-boundaries).
