---
type: Friction Entry
title: "Released PGMQ client lacks inspection statements"
description: "The latest released pgmq-hasql omits the inspection module required by the administration API, so release-based acceptance cannot run."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T04:20:05Z"
frictionId: FRIC-1
status: logged
impact: blocked
kind: interface
origin: "mori://shinzui/shibuya-pgmq-adapter"
affects: "mori://shinzui/pgmq-hs/packages/pgmq-hasql"
plan: "docs/plans/9-expose-adapter-managed-dead-letter-queue-browse-and-redrive.md"
---
# Released PGMQ client lacks inspection statements

## Attempted

Verify a released dependency baseline using the Hackage registry, published Cabal exports, and upstream release tags.

## Encountered

Hackage and upstream tags still end at 0.6.1.1; only the local upstream working tree exports Pgmq.Hasql.Statements.Inspection.

```text
pgmq-hasql-0.6.1.1.cabal has no Pgmq.Hasql.Statements.Inspection export.
```
