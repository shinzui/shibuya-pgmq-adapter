---
title: "FIFO ordered processing"
type: Capability
description: "Opt-in grouped reads for messages tagged with an x-pgmq-group header, including grouped-head reads that enforce per-group FIFO barriers across failures and batched consumption."
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
    proves: All three FIFO strategies dispatch to their matching standard- and long-polling read variants.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/IntegrationSpec.hs
    proves: Grouped-head adapter reads return one head per group, block a failed or delayed group head, and let unrelated groups continue.
  - kind: benchmark
    resource: shibuya-pgmq-adapter-bench/bench/Bench/Fifo.hs
    proves: Safe full-queue drains compare grouped-head batches of 1, 10, and 50 against the legacy safe baseline across single- and multi-group workloads.
  - kind: guide
    resource: docs/user/pgmq-advanced.md
    proves: How FIFO ordering, the x-pgmq-group header, and all three read strategies are configured, including grouped-head version requirements.
---

# FIFO ordered processing

An opt-in mode of the core adapter
([CAP-1: Consume a pgmq queue through Shibuya](./consume-pgmq-queue.md)): set
`fifoConfig` and the adapter reads with pgmq's grouped-read statements so
messages sharing an `x-pgmq-group` header are read with one of three strategies:

- `ThroughputOptimized` fills a batch from the same group first (SQS-like).
- `RoundRobin` distributes reads fairly across groups.
- `HeadPerGroup` returns at most one eligible head from each group, so an
  invisible or delayed head blocks only its own group.

## Shortest usage

```haskell
let config = (defaultConfig queueName)
      { fifoConfig = Just (FifoConfig { readStrategy = HeadPerGroup }) }
```

## Limits

- The original grouped-read capability predates the retained changelog history,
  so its overall `since` value remains undetermined. `HeadPerGroup` is new in
  0.16.0.0.
- `HeadPerGroup` requires PGMQ 1.12.0 or later. The other grouped-read strategies
  remain available with PGMQ 1.8.0 or later.
- The strict failure barrier applies only to `HeadPerGroup`. The two legacy fill
  strategies can lease more than one message from a group in the same batch.
