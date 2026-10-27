# Bundle Update Log

## 2026-10-27
* **Addition**: FRIC-3 records detour interface friction with https://gitlab.haskell.org/ghc/ghc: Nanosecond runtime timer quantizes short latency measurements
* **Addition**: FRIC-2 records detour tooling friction with https://github.com/haskell/cabal: Incremental Cabal build retains incompatible dependency identities
* **Update**: FRIC-1 resolved: The inspection dependency is released; remove the temporary-source blocker while preserving performance acceptance.

## 2026-10-26
* **Addition**: FRIC-1 records blocked interface friction with mori://shinzui/pgmq-hs/packages/pgmq-hasql: Released PGMQ client lacks inspection statements
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
