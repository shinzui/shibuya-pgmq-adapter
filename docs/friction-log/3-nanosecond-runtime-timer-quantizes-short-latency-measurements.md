---
type: Friction Entry
title: "Nanosecond runtime timer quantizes short latency measurements"
description: "The GHC monotonic nanosecond API advances in microsecond steps on this macOS host, too coarse for the short worker latency budget."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-27T03:59:10Z"
frictionId: FRIC-3
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/shibuya-pgmq-adapter"
affects: "https://gitlab.haskell.org/ghc/ghc"
affectedVersion: "9.12.4"
plan: "docs/plans/9-expose-adapter-managed-dead-letter-queue-browse-and-redrive.md"
workaround: "Use a benchmark-only Darwin C API call to clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), identically in controls and candidate; retain the portable GHC clock elsewhere."
---
# Nanosecond runtime timer quantizes short latency measurements

## Attempted

Measure per-acknowledgement p95 with GHC.Clock.getMonotonicTimeNSec under the original 10% budget.

## Encountered

Every measured delta has a 1000ns common divisor; one remaining bound was 31/28 = 1.107142857 against a 1.10 budget.

```text
.dev/check-dlq-clock.log: GHC positive deltas [1000,11000], gcd 1000; CLOCK_MONOTONIC_RAW positive deltas [41,42,83,84,125], gcd 1.
```

## Workaround

Use a benchmark-only Darwin C API call to clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), identically in controls and candidate; retain the portable GHC clock elsewhere.
