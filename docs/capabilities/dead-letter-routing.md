---
title: "Dead-letter routing"
type: Capability
description: "Opt-in dead-letter handling that moves a failed or over-retried message to a target queue in one PostgreSQL transaction, preserving a queryable reason code and optional detail alongside the compatibility rendering."
generated:
  by: codex/1.0
  at: "2026-08-10T21:15:04Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-20T21:05:00Z"
    document_timestamp: "2026-08-10T21:15:04Z"
    scope: content-and-metadata
    outcome: approved
    context: "Repository source, the full adapter test suite, capability evidence, and the EP-41 lifecycle audit."
    provider: openai
    model: gpt-6-astra
    effort: high
capabilityId: CAP-2
provider: mori://shinzui/shibuya-pgmq-adapter
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-pgmq-adapter
interface:
  - Shibuya.Adapter.Pgmq.PgmqAcknowledgementException
  - Shibuya.Adapter.Pgmq.Config
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs
    proves: Against real ephemeral PostgreSQL, an ApplicationFailure reaches the DLQ with exact JSONB-queryable rendered, code, and detail fields; discarded commit confirmation and concurrent finalization converge on one copy; failed moves preserve the source and reach LifecycleFailed; automatic failures reach the hook and caller; and restart preserves lease-expiry redelivery.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConvertSpec.hs
    proves: Exact payload objects cover every released reason, both metadata modes, null versus empty detail, and Unicode and JSON-escaping cases.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/PropertySpec.hs
    proves: For generated reasons, mkDlqPayload derives the three reason fields from Shibuya's total public projections and includes metadata keys iff configured.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConfigSpec.hs
    proves: The directDeadLetter and topicDeadLetter smart constructors build the expected DeadLetterTarget and includeMetadata.
  - kind: guide
    resource: docs/user/pgmq-dead-letter-queues.md
    proves: How to configure, query, index, and migrate the dual-written DLQ contract, including detail safety and topic fan-out cost.
  - kind: benchmark
    resource: shibuya-pgmq-adapter-bench/bench-dlq/Main.hs
    proves: Fully encoded legacy and dual-write payloads have bounded constant work plus linear copying as application detail grows.
---

# Dead-letter routing

An opt-in extension of the core adapter
([CAP-1: Consume a pgmq queue through Shibuya](./consume-pgmq-queue.md)): set
`deadLetterConfig` and a message that is dead-lettered — by an explicit
`AckDeadLetter` decision or by exceeding `maxRetries` — is written to a
dead-letter target instead of being archived. The DLQ send and the source
delete run in a single `ReadCommitted` PostgreSQL transaction, and finalizers
are durably idempotent, so a retried ack cannot double-send. The transaction
first deletes the source row and sends only when that delete returns `True`.
PostgreSQL rolls the delete back if the send fails; after an ambiguous commit,
the retry sees `False` and becomes a no-op.

Each in-memory acknowledgement handle also serializes concurrent calls. A
successful decision marks the handle complete, while failure or cancellation
releases ownership without marking it complete. An exhausted database error
invokes `onAckFailure` and is thrown as `PgmqAcknowledgementException`, allowing
Shibuya core to retain a failed lifecycle instead of reporting graceful stop.

The target is either a queue named directly (`directDeadLetter`) or a routing
key resolved by topic routing (`topicDeadLetter`, see CAP-6,
Topic-based routing). With
`includeMetadata`, the DLQ payload carries the original message id, enqueue
time, last-read time, read count, and headers alongside the original body. Every
new DLQ body carries the canonical `dead_letter_reason` compatibility string,
the stable `dead_letter_reason_code`, and an always-present
`dead_letter_reason_detail` that is JSON null when no detail exists.

## Shortest usage

```haskell
let config = (defaultConfig queueName)
      { deadLetterConfig = Just (directDeadLetter dlqQueueName True) }
```

## Limits

- **The reliability guarantees are newer than the feature.** DLQ support ships
  from 0.1.0.0 and single-transaction send/delete from 0.9.0.0. The
  delete-first ambiguous-commit protection, concurrent finalizer ownership, and
  typed terminal failure route are part of the next release after 0.16.0.0;
  consumers on older versions do not have those stronger guarantees.
- **Direct-queue routing is the integration-tested path.** The chaos evidence
  drives `directDeadLetter`. The `topicDeadLetter` / `TopicRoute` send path is
  only unit-tested at the smart-constructor level; its end-to-end behavior
  inherits the weaker evidence of CAP-6 (Topic-based routing).
- **The guarantee is per source identity.** Reconstructing or concurrently
  retaining callbacks is safe because the source-row claim is durable. This is
  not an exactly-once guarantee for application handler side effects, which may
  still replay under the adapter's at-least-once delivery contract.
- **No DLQ means archive.** With `deadLetterConfig = Nothing`, `AckDeadLetter`
  archives the message via pgmq rather than routing it anywhere.
- **The compatibility field is temporary.** Version 0.14 dual-writes the legacy
  string and structured values. Readers should prefer code/detail and fall back
  to the string for retained older rows.
- **Detail and indexing are operator policy.** The adapter neither truncates
  detail nor installs a JSONB index. Applications must keep detail bounded and
  free of secrets, full payloads, raw SQL, and unrestricted backend errors.
  Operators can index `message ->> 'dead_letter_reason_code'` for a large DLQ.
  Topic routing multiplies encoding-adjacent network, WAL, and storage cost by
  every matching queue.
