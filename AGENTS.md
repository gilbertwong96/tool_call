# VibeKit quality gate

## Development

```sh
mix deps.get
mix ci
mix coveralls.html
```

## Conventions

- Use `mix ci` for the full validation suite before finishing changes. It runs
  `compile --warnings-as-errors`, `format --check-formatted`, `test`,
  `spec_lint --warnings-as-errors`, `credo --strict`, `dialyzer`,
  `ex_dna --max-clones 0` and `reach.check --arch --smells` in the `test`
  environment.
- Use `mix coveralls.html` to write the coverage report to `cover/`.
- Keep changes small, tested, and formatted.
- Every module under `lib/` needs a real `@moduledoc`. `@moduledoc false` is not
  accepted, including for internal helper modules; describe what the module owns
  and what it deliberately does not do.
- Never use Python/Perl/shell one-off scripts for code migrations, API renames,
  or bulk edits. Use the pi-elixir workflow in
  [Refactoring with pi-elixir](#refactoring-with-pi-elixir).
- `.credo.exs` and `.reach.exs` come from the VibeKit 0.1.7 installer. VibeKit
  itself is not a dependency: re-run `mix igniter.install vibe_kit --agents-md`
  only if the quality config needs regenerating, then check that it did not
  duplicate this file or drop the `only: [:dev, :test]` restrictions on the
  quality tools.

## Refactoring with pi-elixir

Match the tool to the shape of the change, and prefer the semantic one.

| Change | Tool |
|---|---|
| Find code by structure | `elixir_ast_search` |
| Rewrite code by structure | `elixir_ast_replace` (dry run first) |
| Rename a module, function, variable | LSP `rename` |
| Small, exact, local edit | `edit` |
| Inspect behaviour at runtime | `elixir_eval` |

Rules:

- Search by AST before rewriting. A pattern that matches the wrong nodes is a
  design mistake in the pattern, not a reason to fall back to text.
- Dry-run every `elixir_ast_replace` and read the diff before applying it.
- Prefer LSP `rename` over AST rewriting for symbols: it moves every reference,
  including remote calls, and leaves unrelated same-named locals alone.
- Reserve `edit` for changes where the exact old text is unique and short.
- After any structural rewrite, run `mix format` and `mix ci`. An AST rewrite
  that compiles can still change semantics.

Why: text scripts match substrings, not syntax. `sed`, `awk`, and one-off
Python/Perl scripts also hit comments, strings, docs, and similarly named locals,
and cannot tell a local `ref/3` from a dependency's. The failure mode is silent
semantic drift found much later, after the diff is long and the context is gone.
