# Schema projection matrix

`ToolCall.Emit.Schema` projects the provider-neutral `ToolCall.IR` into JSON
Schema. The target emitters then adapt that schema to their wire format. This
file is the canonical description of what survives each projection. The
emitters are authoritative; the tests in `test/projection_test.exs` pin the
cells below.

## Wire envelopes

| | OpenAI | Anthropic | MCP | Gemini |
|---|---|---|---|---|
| Shape | `{"type":"function","function":{...}}` | `{name, description, input_schema}` | `{name, description, inputSchema}` | `{name, description, parameters}` in `functionDeclarations` |
| Top level | must be an object | any JSON Schema | an object schema (`type: "object"`) | an object schema (`type: "OBJECT"`) |
| Type casing | lowercase JSON Schema | lowercase JSON Schema | lowercase JSON Schema | uppercase OpenAPI `Type` enum |
| Nullability | `["T", "null"]` | `["T", "null"]` / `anyOf` | same as OpenAI | `nullable: true` |
| Who parses arguments | you (a JSON string) | the provider (`input` arrives decoded) | varies | the provider (a `functionCall` map) |

## Targets

| Construct | OpenAI | OpenAI strict | OpenAI fine-tuned | Anthropic | MCP | Gemini |
|---|---|---|---|---|---|---|
| `union` | `anyOf` | `anyOf` | `anyOf` | `anyOf` | `anyOf` | `anyOf`; a null branch becomes `nullable: true` |
| numeric bounds | kept | kept | dropped | kept | kept | kept |
| `pattern` / `format` | kept | kept | dropped | kept | kept | kept; non-string enums are dropped |
| `minItems` / `maxItems` | kept | kept | dropped | kept | kept | kept |
| `$ref` / `$defs` | kept | kept | kept | kept | kept | rejected; a recursive parameter raises |
| tuple positions | `prefixItems` | dropped | dropped | `prefixItems` | `prefixItems` | dropped |
| open object | open | closed | closed | open | open | `additionalProperties` dropped |
| `:any` / `:unsupported` | `{}` | `{}` | `{}` | `{}` | `{}` | `{}` |

`OpenAI strict` means `strict: true`. `OpenAI fine-tuned` means
`strict: :fine_tuned`, which also implies the strict shape; it drops `pattern`,
`format`, numeric bounds and array bounds because fine-tuned models reject
them. MCP passes `strict: true` through to the shared schema and therefore
closes objects; MCP has no strict flag of its own. Gemini ignores `strict` and
adapts the shared schema to its OpenAPI 3.0 subset.

## Target-specific notes

### OpenAI

The normal target emits the shared JSON Schema inside
`{"type":"function","function":{...}}`. `strict: true` adds the flag, makes
every property required, widens optional values to `["T","null"]`, and closes
every object. Tuple positions are dropped in strict mode because OpenAI rejects
`prefixItems`; `minItems` and `maxItems` remain. `strict: :fine_tuned` renders
the same shape without `pattern`, `format`, numeric bounds or array bounds.

### Anthropic

Anthropic receives the shared schema as `input_schema`; `strict` is not part of
its tool definition. `prefixItems`, `$ref`/`$defs`, bounds, patterns and formats
are preserved.

### MCP

MCP receives the shared schema as `inputSchema`. It is plain JSON Schema and has
no strict flag, but `strict: true` still renders the closed subset, which is
valid JSON Schema. MCP itself does not add constraints.

### Gemini

Gemini's `parameters` is a 22-field OpenAPI 3.0 subset, not JSON Schema. It has
no `additionalProperties`, `$ref`/`$defs`, `oneOf`, `prefixItems` or `const`.
The emitter:

- drops `additionalProperties`, so an object stays open;
- drops `prefixItems`, so a tuple keeps only `minItems`/`maxItems`;
- drops non-string enums;
- collapses a null `anyOf` branch into `nullable: true`;
- raises for a recursive parameter instead of emitting an invalid schema.

`parametersJsonSchema` accepts full JSON Schema but is not emitted by
`ToolCall.emit/3`.

## Current IR limits

`ToolCall.IR.Type` has no intersection or negation kind, and no emitter writes
`allOf` or `not`; Gemini's subset rejects both. `TypeExpr` therefore lowers a
set operation only when the result is representable exactly, through
`ToolCall.TypeExpr.Projection`:

| Operation | Lowered exactly | Degrades to `:unsupported` |
|---|---|---|
| `:any` / `:none` identity | yes | — |
| integer ranges and `integer()` | overlap, emptiness | — |
| literals and enums | overlap, difference, narrowing against primitives | — |
| maps | field and `additionalProperties` merge; a closed side keeps the object closed | conflicting field types |
| tuples | same-arity position-wise merge; `tuple()` is the identity | different arity |
| identical `ref` / `remote` | the node itself | different targets |
| strings | pattern/format/source narrowing when they agree | two different patterns, formats, or sources |
| `and not <range>` | split into at most two ranges | — |
| `and not <union>` | each variant subtracted in turn | — |
| other intersections | — | disjoint kinds, provider types |
| bare complement (`not t`) | — | no exact JSON Schema form |

An inexact operation yields `{:unsupported, :intersection}` (or `:negation`) and
the build warns with the existing "no JSON representation" message. It is never
silently widened to `anyOf` or `any`, because that would tell the model the wrong
contract.

A future native type source that needs more than these cases must either add an
IR representation with emitter tests or report a diagnostic.
