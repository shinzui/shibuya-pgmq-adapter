---
type: Bug Report
title: Retried dead-letter move can duplicate a copy
description: >-
  Adapter 0.16.0.0 sends a DLQ copy before deleting the source row in one
  transaction, so retrying after an ambiguous successful commit can send a
  second copy even though the source is already absent.
generated:
  by: openai/codex
  at: "2026-09-28T00:06:38Z"
bugId: BUG-3
status: fixed
severity: degraded
fixedVersion: "0.16.1.0"
resolution: >-
  Version 0.16.1.0 claims the source row by deleting it first in the same
  transaction and sends a DLQ copy only when that delete returns True. A failed
  send rolls back the deletion, while a retry after a committed move sees no
  source row and becomes a no-op. Isolated published 0.16.1.0 PostgreSQL 17
  and 18 runs moved 10,000 original IDs per fault arm without duplicates.
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter
capability: mori://shinzui/shibuya-pgmq-adapter/okf/capabilities/concepts/CAP-2
affectedVersion: "0.16.0.0"
environment: >-
  Adapter 0.16.0.0 on durable PostgreSQL 18, direct dead-letter queue with
  includeMetadata enabled, 10,000 messages in each of two arms, backend
  termination during finalization and a separate lost-COMMIT-response arm.
observed: >-
  The pinned historical adapter emitted nine extra DLQ copies in the
  10,000-message backend-termination arm; a 1,000-message replay emitted two.
  No original ID was lost. The lost-COMMIT-response arm passed in these runs.
expected: >-
  Every original ID has exactly one DLQ copy after a completed dead-letter move.
  A retry after a committed move must not send another copy, even if the client
  could not observe the first transaction's response.
reproduction:
  - Create source and direct DLQ queues on durable PostgreSQL 18 and send 10,000 uniquely identified messages.
  - Have a handler return AckDeadLetter; terminate consumer backends at handler-count thresholds while the restart loop renews its pool.
  - Sample source and DLQ IDs in one MVCC statement and drain the run; count DLQ copies by original_message_id.
  - On 0.16.0.0, the pinned fault schedule produced nine duplicate copies; repeat on 0.16.1.0 and observe at most one per ID.
workaround: >-
  Upgrade to adapter 0.16.1.0 or later. Consumers of historical DLQ copies
  should deduplicate by original_message_id when includeMetadata is enabled.
---

# Retried dead-letter move can duplicate a copy

The historical `v0.16.0.0` source sends the DLQ message before it deletes the
source row in a `ReadCommitted` transaction. When a prior transaction committed
but its response was lost, retrying the finalizer can send another DLQ copy;
deleting the absent source row afterward does not retract that send. The
0.16.1.0 source reverses those statements and gates the send on the delete
result. This is the fix described by
`mori://shinzui/shibuya/plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults`.

The external `shibuya/pgmq-adapter/concurrency/dead-letter-move-is-atomic`
scenario in `mori://shinzui/keiro-runtime-kenshou` recorded the 1,000-message
reproduction at `runs/01a0ddb7-bdd1-7204-bd0f-756e7c698b12/run-result.json`
and the full 10,000-message reproduction at
`runs/01a0ddbe-0d8f-74c9-b010-9478ea1edc9f/run-result.json`
(artifact-level URIs pending). A separate historical PostgreSQL 18 fault
schedule did not yield duplicates, so the result depends on the fault timing.
Current 0.16.1.0 PostgreSQL 18 and 17 sealed runs passed at
`runs/01a0ddd5-f6cd-74fa-8a0c-e9412f4b6ba3/run-result.json` and
`runs/01a0ddd6-4b62-779d-b81c-cf3f50bfcef5/run-result.json` in the same
project (artifact-level URIs pending).
