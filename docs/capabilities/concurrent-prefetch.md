---
title: "Concurrent prefetch"
type: Capability
description: "Opt-in background prefetch that polls the next batches on a worker while the current messages are handled, overlapping database latency with handler work, with a bounded and loss-free shutdown."
generated:
  by: claude-code/1.0
  at: "2026-08-08T00:00:00Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-20T21:05:00Z"
    document_timestamp: "2026-08-08T00:00:00Z"
    scope: content-and-metadata
    outcome: approved
    context: "Repository source, the full adapter test suite, capability evidence, and the EP-41 lifecycle audit."
    provider: openai
    model: gpt-6-astra
    effort: high
capabilityId: CAP-4
provider: mori://shinzui/shibuya-pgmq-adapter
status: shipped
stability: experimental
since: "0.10.0.0 (reintroduced; an earlier form was removed in 0.9.0.0)"
packages:
  - shibuya-pgmq-adapter
interface:
  - Shibuya.Adapter.Pgmq.Config
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs
    proves: Against a real PostgreSQL, prefetch drains the queue without deadlocking, strands at most one prefetch buffer of extra messages on shutdown, and loses no messages — every stranded message is redelivered after the visibility timeout.
  - kind: module
    resource: shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs
    proves: PrefetchConfig documents the visibility-timeout trade-off and the bounded, at-least-once-safe shutdown behaviour; validateConfig rejects a bufferSize of 0.
---

# Concurrent prefetch

An opt-in performance mode of the core adapter
([CAP-1: Consume a pgmq queue through Shibuya](./consume-pgmq-queue.md)): set
`prefetchConfig` and the polling stage reads the next batches on a background
worker while the current messages are being processed, overlapping database
latency with handler work. Only the polling stage runs under effectful's
`ConcUnlift` strategy (scoped locally), so the non-prefetch path is unchanged
and carries no added overhead.

## Shortest usage

```haskell
let config = (defaultConfig queueName)
      { prefetchConfig = Just defaultPrefetchConfig }  -- buffers 4 batches ahead
```

## Limits

- **Prefetched messages have their visibility timeout ticking while buffered.**
  Ensure `bufferSize * batchSize * avgProcessingTime < visibilityTimeout`, or a
  message can become visible to another consumer before it is handled.
- **Shutdown is loss-free but not prompt.** Unlike the non-prefetch path (which
  releases undispatched messages immediately), up to `bufferSize * batchSize`
  buffered messages stay invisible until their visibility timeout expires. No
  message is lost — redelivery is merely delayed. This bound is what the chaos
  suite asserts.
- **Reintroduced feature.** An earlier prefetch implementation was removed in
  0.9.0.0 because it could deadlock (`thread blocked indefinitely in an STM
  transaction`). The current implementation dates from 0.10.0.0; the `since`
  above reflects that, not the original 0.1.0.0 form.
