---
title: "FIFO ordered processing"
type: Capability
description: "Opt-in grouped reads that keep per-group ordering for messages tagged with an x-pgmq-group header, with a throughput-optimized or round-robin batch-fill strategy."
generated:
  by: claude-code/1.0
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-3
provider: mori://shinzui/shibuya-pgmq-adapter
status: shipped
stability: experimental
since: "undetermined"
packages:
  - shibuya-pgmq-adapter
interface:
  - Shibuya.Adapter.Pgmq.Config
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/InternalSpec.hs
    proves: mkReadGrouped builds the grouped-read query (queue, visibility timeout, qty) from config, and the poll dispatch selects the grouped / grouped-round-robin read variants.
  - kind: benchmark
    resource: shibuya-pgmq-adapter-bench/bench/Bench/Fifo.hs
    proves: The grouped read path runs end-to-end under a throughput benchmark against a real pgmq queue.
  - kind: guide
    resource: docs/user/pgmq-advanced.md
    proves: How FIFO ordering, the x-pgmq-group header, and the two read strategies are configured.
---

# FIFO ordered processing

An opt-in mode of the core adapter
([CAP-1: Consume a pgmq queue through Shibuya](./consume-pgmq-queue.md)): set
`fifoConfig` and the adapter reads with pgmq's grouped-read statements so
messages sharing an `x-pgmq-group` header preserve their order. Two strategies
trade throughput against fairness:

- `ThroughputOptimized` fills a batch from the same group first (SQS-like).
- `RoundRobin` distributes reads fairly across groups.

## Shortest usage

```haskell
let config = (defaultConfig queueName)
      { fifoConfig = Just (FifoConfig { readStrategy = RoundRobin }) }
```

## Limits

- **`since` is undetermined.** FIFO configuration is present in the current
  source but is not itemized in `CHANGELOG.md`, so the release it first shipped
  in cannot be established from release history. Do not assume it exists in an
  arbitrary older pin.
- **Ordering itself is not proven in this repository.** The evidence here proves
  that the grouped-read *query* is constructed and dispatched, and that the path
  runs under a benchmark — not that end-to-end per-group ordering or round-robin
  fairness holds. The ordering guarantee is pgmq's; this repository has no
  integration or property test asserting it. This is the weakest-evidenced
  capability in the catalog.
