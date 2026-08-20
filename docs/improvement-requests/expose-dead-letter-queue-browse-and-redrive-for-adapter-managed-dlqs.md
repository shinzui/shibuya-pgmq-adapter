---
type: Improvement Request
title: Expose dead-letter-queue browse and redrive for adapter-managed DLQs
description: >-
  Add a read surface over adapter-managed dead-letter queues — list entries with their
  structured reason code, reason detail, attempt count, and original queue; fetch one entry —
  plus an explicit, gated redrive operation, so an operator can see why messages died and
  safely return them to their source queue.
timestamp: 2026-08-19T00:00:00Z
requestId: IR-3
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Expose Dead-Letter-Queue Browse and Redrive for Adapter-Managed DLQs

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/4-audit-shibuya-and-file-ui-endpoint-improvement-requests`).
The DLQ payload contract this request reads back is the one this repository shipped under
`mori://shinzui/shibuya-pgmq-adapter/okf/improvement-requests/concepts/IR-1` (completed) —
this request is its natural continuation: first the reasons were preserved, now the operator
gets to see them. Implementation is the adapter's own downstream work.

## Context

When a message permanently fails, the adapter routes it to a dead-letter queue with structured
payload fields — `dead_letter_reason_code` (a validated dotted code) and `dead_letter_reason`
(detail JSON) — delivered under this repository's plans 5 and 6, and the
`PgmqAdapterEnv.onAutoDeadLetter`/`onAckFailure` callbacks fire on the way. But the story ends
there: nothing reads a DLQ back, and nothing returns a message to its source queue (audited
2026-08-19 at commit `fee9b3a`, re-confirmed at filing time). For an operator, the dead-letter
view is the primary "what went wrong" screen, and redrive is the primary recovery action after
fixing the underlying cause; today both require raw SQL against pgmq tables.

The layering rule (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`) puts this here rather
than in pgmq-hs or shibuya core: pgmq-hs sees only queues (a DLQ is just another queue to it —
its non-destructive browsing, requested as
`mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-1`, can page any queue's raw
messages); shibuya core knows only `AckDeadLetter` decisions. Only this adapter knows which
queues are DLQs, which source queue each serves, and what the structured payload envelope
means. Decoding reasons and redriving to the correct source queue are adapter semantics.

## Requested Change

1. A read surface over adapter-managed DLQs: list a DLQ's entries — decoded to reason code,
   reason detail JSON (structure intact), attempt/read count, original queue, and enqueue
   time — with bounded, cursor-style pagination; and fetch a single entry by message id.
   Reads must be non-destructive (no visibility-timeout mutation on browsed messages),
   building on pgmq-hs's non-destructive reads (pgmq-hs IR-1) when those land, with the
   adapter's own decoding layered on top.
2. An explicit **redrive** operation returning a chosen dead-lettered message to its source
   queue. Redrive is a mutation and must be gated per the initiative's control-plane posture:
   disabled unless explicitly enabled in configuration, idempotent in effect (a message
   redriven twice does not duplicate), and its outcome observable (the DLQ entry is gone, the
   message is in the source queue).
3. Optionally, a live dead-letter feed built on the existing `onAutoDeadLetter`/`onAckFailure`
   callbacks, following the cross-project live-update rule
   (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3`): the feed is a latency optimization
   over the browsable read surface, never the source of truth.
4. Any HTTP exposure follows the cross-project conventions (project
   `mori://shinzui/keiro-ui`, path `docs/architecture/inspection-api-conventions.md`,
   artifact-level URI pending); an in-process API that a host or metrics surface can serve is
   the minimum.

## Acceptance

1. Against the adapter's real-database test harness, after a handler returns `AckDeadLetter`
   with an application-defined reason, the browse surface lists the entry with its exact
   `dead_letter_reason_code`, structured reason detail, attempt count, and original queue.
2. Browsing leaves DLQ messages untouched: visibility timeouts and read counts are unchanged
   after a listing (asserted on raw rows).
3. With redrive enabled, redriving the entry removes it from the DLQ and makes it available
   on its source queue exactly once; with redrive disabled (the default), the operation
   refuses with a structured error and changes nothing. Both paths tested.
4. Fetch-by-id returns the decoded entry when present and a typed not-found when absent.
5. If the live feed is built: a subscriber receives the new dead-letter event after an
   `AckDeadLetter`, and killing the feed's transport does not lose the entry — it remains
   visible in the browse surface (push is a hint; poll is truth).

## Requested Deliverables

The browse/fetch API and gated redrive with tests on the real-database harness, documentation
of the redrive gate and its safety semantics, the optional live feed if pursued, and a durable
record of the gating decision (this repository keeps durable context in its plans and OKF
records; the venue is the implementer's choice — the recorded decision is the deliverable).
