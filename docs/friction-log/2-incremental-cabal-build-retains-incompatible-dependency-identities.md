---
type: Friction Entry
title: "Incremental Cabal build retains incompatible dependency identities"
description: "The reused build directory produced missing effect-handler errors after dependency and optimization changes; a fresh build directory compiled all components."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-27T02:23:36Z"
frictionId: FRIC-2
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/shibuya-pgmq-adapter"
affects: "https://github.com/haskell/cabal"
plan: "docs/plans/9-expose-adapter-managed-dead-letter-queue-browse-and-redrive.md"
workaround: "Use --builddir=dist-dlq-release to rebuild local components against the current released dependency identities; .dev/dlq-final-build-clean.log retains the successful build."
resolution: "Use a fresh Cabal build directory for each dependency and optimization configuration; isolated directories consistently compile against the intended package identities."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-27T13:10:35Z"
    change: "Accept isolated build directories as the release-check workaround; no upstream defect claim is established."
---
# Incremental Cabal build retains incompatible dependency identities

## Attempted

nix develop --no-write-lock-file -c cabal build all --enable-tests

## Encountered

Examples and benchmark workers report missing Tracing/Pgmq effect handlers despite a consistent current solver plan.

```text
GHC-64725: There is no handler for shibuya-core-0.12.0.0:Shibuya.Telemetry.Effect.Tracing in the context; .dev/dlq-final-build.log retains the diagnostics.
```

## Workaround

Use --builddir=dist-dlq-release to rebuild local components against the current released dependency identities; .dev/dlq-final-build-clean.log retains the successful build.
