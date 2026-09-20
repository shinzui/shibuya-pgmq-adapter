# ADR 0001: Claim the source row before producing a dead-letter copy

Status: Accepted

Date: 2026-09-20

## Context

PGMQ dead-lettering moves one source message into a configured target inside a
PostgreSQL transaction. The former transaction inserted the DLQ row before
deleting the source and ignored the delete result. If the database committed
but the client lost the commit response, retry could insert another DLQ row
after the source had already disappeared. The in-memory completion flag could
not make this crash-safe and was also not safe for concurrent callers.

This decision implements
`mori://shinzui/shibuya/plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults`.

## Decision

Within the existing `ReadCommitted` write transaction, delete the source row
first and inspect PGMQ's Boolean result. Produce the direct-queue or topic-routed
DLQ copy only when the delete returned `True`.

Serialize calls made through one `AckHandle` with exception-safe ownership.
Mark it complete only after its decision succeeds. Convert an exhausted
`PgmqRuntimeError` into the public synchronous
`PgmqAcknowledgementException` after invoking `onAckFailure`.

No idempotency table, schema migration, or DLQ uniqueness index is added.

## Consequences

- A successful commit followed by a lost response is safe to retry: the source
  row is absent, so no second DLQ copy is produced.
- If sending fails, transaction rollback restores the source row. The move
  cannot commit a delete without its corresponding DLQ copy.
- Concurrent or reconstructed callbacks converge through the durable source-row
  claim. Per-handle serialization additionally protects non-DLQ decisions and
  makes cancellation retryable.
- This preserves at-least-once message delivery. It does not provide exactly-once
  application side effects.
- Exhausted finalization is now an observable processor failure rather than a
  successful return through the `Error PgmqRuntimeError` channel.
