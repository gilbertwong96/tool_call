# Roadmap

The published line is `0.1.0`. The `0.2`–`0.4` features are implemented and
awaiting a release; the completed feature set is recorded in
[`CHANGELOG.md`](../CHANGELOG.md) and the usage guide. This file tracks only
work that is not implemented yet.

## Later / not scheduled

These are useful additions without a target release yet:

- Optional standard-library type providers for `URI` and `Version` (string
  wire forms). `Range` stays a struct object; `Decimal` is intentionally not
  built in because it requires the external `decimal` package.
- Nested or remote typedoc inheritance if a description-composition model is
  chosen.

## Design boundaries

The limits that are intentional rather than planned are documented in
[`design.md`](design.md#design-boundaries).
