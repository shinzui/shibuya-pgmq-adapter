# ADR 0002: Register managed DLQs and claim each entry before redrive

Status: Accepted

Date: 2026-10-25

## Context

Operators need to browse failures without leasing them and explicitly return a
chosen original payload to its source. Physical DLQs can be shared by several
sources, and topic routing can create several distinct copies of one failure.
Historical envelopes lack a source queue. Payload content alone must not grant
permission to publish into an arbitrary queue.

This decision extends [ADR 0001](0001-idempotent-dead-letter-moves.md) in the
reverse direction and implements [plan 9](../plans/9-expose-adapter-managed-dead-letter-queue-browse-and-redrive.md).
Queue inspection mechanics belong to `mori://shinzui/pgmq-hs/packages/pgmq-hasql`;
adapter-managed envelope interpretation and redrive belong to this adapter.

## Decision

Keep administration configuration separate from worker configuration. A host
registers each physical DLQ and its allowed source queues, provides a borrowed
administrative pool connected to the same database, and explicitly enables
redrive. The gate defaults off and is checked before database access. A handle
starts no threads and performs no queries. Finite statement and lock timeouts
are transaction-local. Host transports supply their own caller authorization.

New adapter writes include `original_queue` regardless of optional metadata.
Preserve the old `mkDlqPayload` output and all reason compatibility fields.
Structured reason fields are authoritative whenever either exists; malformed
rows remain inspectable with their raw data. Legacy reason text is inferred only
when both structured fields are absent. Missing original delivery metadata stays
unknown. A historical row without a source uses a clearly marked fallback only
when registration names exactly one source; otherwise redrive refuses it.

Browse/fetch compose upstream non-destructive inspection statements in read-only
transactions. Redrive locks and decodes the selected current row, authorizes its
source against registration, deletes it, and sends only after a successful claim,
all in one ReadCommitted write transaction. A send failure restores the deletion
through rollback. Do not create source queues or retry an isolated send. Let
cancellation unwind the operation. No receipt table or schema migration is added.

## Consequences

- Repeated or concurrent calls for one physical DLQ and message ID insert at
  most once while that queue identity lives. An uncertain commit can be retried
  as a complete operation. `AlreadyAbsent` cannot identify who removed the row.
- Different topic fan-out copies are separate claims and can each be redriven.
  This is not global deduplication or exactly-once handler side effects.
- Redrive sends the original JSON, including valid null, with saved original
  headers when present. Explicit null is distinct from absent original headers;
  only absence falls back to the DLQ headers, whose trace context may have changed.
  Redrive assigns a new ID, zero read count, new enqueue time and queue-tail
  position; it cannot restore the original FIFO position.
- Cursors are queue-bound moving views, not snapshots or replay tokens. Refresh
  the first page for late lower IDs. Row limits bound neither JSON bytes nor scan
  work. Separate pools reserve connections but do not isolate database CPU/I/O.
  Numeric performance acceptance is tracked by plan 9 and requires measurement.
- Queue recreation ends the message-ID identity lifetime. Hosts must not replay
  old operator requests after dropping and recreating queues.
