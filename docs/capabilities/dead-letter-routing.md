---
title: "Dead-letter routing"
type: Capability
description: "Opt-in dead-letter handling that moves a failed or over-retried message to a target queue (directly or by topic routing key), optionally with original metadata, in one PostgreSQL transaction with the source delete."
generated:
  by: claude-code/1.0
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-2
provider: mori://shinzui/shibuya-pgmq-adapter
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-pgmq-adapter
interface:
  - Shibuya.Adapter.Pgmq.Config
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs
    proves: Against a real PostgreSQL, a handler returning AckDeadLetter (and a poison message) moves the message to the configured DLQ, and AckDeadLetter is idempotent after a successful finalize.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/PropertySpec.hs
    proves: mkDlqPayload always carries original_message and dead_letter_reason keys, and includes the metadata keys iff includeMetadata is set.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConfigSpec.hs
    proves: The directDeadLetter and topicDeadLetter smart constructors build the expected DeadLetterTarget and includeMetadata.
  - kind: guide
    resource: docs/user/pgmq-dead-letter-queues.md
    proves: How to configure DLQ handling, including metadata inclusion and topic-based routing.
---

# Dead-letter routing

An opt-in extension of the core adapter
([CAP-1: Consume a pgmq queue through Shibuya](./consume-pgmq-queue.md)): set
`deadLetterConfig` and a message that is dead-lettered — by an explicit
`AckDeadLetter` decision or by exceeding `maxRetries` — is written to a
dead-letter target instead of being archived. The DLQ send and the source
delete run in a single `ReadCommitted` PostgreSQL transaction, and finalizers
are idempotent, so a retried ack cannot double-send.

The target is either a queue named directly (`directDeadLetter`) or a routing
key resolved by topic routing (`topicDeadLetter`, see CAP-6,
Topic-based routing). With
`includeMetadata`, the DLQ payload carries the original message id, enqueue
time, last-read time, read count, and headers alongside the original body and a
`dead_letter_reason`.

## Shortest usage

```haskell
let config = (defaultConfig queueName)
      { deadLetterConfig = Just (directDeadLetter dlqQueueName True) }
```

## Limits

- **The transactional atomicity is newer than the feature.** DLQ support ships
  from 0.1.0.0, but the single-transaction send+delete and idempotent-finalizer
  guarantees described here arrived in 0.9.0.0. A consumer pinned below 0.9.0.0
  gets DLQ routing without those reliability guarantees.
- **Direct-queue routing is the integration-tested path.** The chaos evidence
  drives `directDeadLetter`. The `topicDeadLetter` / `TopicRoute` send path is
  only unit-tested at the smart-constructor level; its end-to-end behavior
  inherits the weaker evidence of CAP-6 (Topic-based routing).
- **No DLQ means archive.** With `deadLetterConfig = Nothing`, `AckDeadLetter`
  archives the message via pgmq rather than routing it anywhere.
