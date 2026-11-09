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
- `.credo.exs` and `.reach.exs` come from the VibeKit 0.1.7 installer. VibeKit
  itself is not a dependency: re-run `mix igniter.install vibe_kit --agents-md`
  only if the quality config needs regenerating, then check that it did not
  duplicate this file or drop the `only: [:dev, :test]` restrictions on the
  quality tools.
