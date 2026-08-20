---
type: Improvement Request
title: Surface queue depth and age context for processors consuming pgmq queues
description: >-
  Expose, per configured queue, depth and oldest-message age alongside the processor that
  consumes it — sourced from pgmq-owned surfaces rather than a duplicate adapter metrics API —
  so an operator can see how much work is waiting behind a processor.
timestamp: 2026-08-19T00:00:00Z
requestId: IR-2
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Surface Queue Depth and Age Context for Processors Consuming pgmq Queues

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/4-audit-shibuya-and-file-ui-endpoint-improvement-requests`).
Queue-backed context for a processor belongs to the shibuya adapters per the initiative's
layer-ownership matrix (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`): shibuya core
deliberately knows nothing about queues, and only this adapter knows which pgmq queues a
processor consumes and holds the connection to reach them. Implementation is the adapter's own
downstream work.

## Context

An operator looking at a processor's metrics today sees its own activity — state, counters,
in-flight count — but nothing about the queue behind it: how deep it is, or how old its oldest
waiting message is. Those two numbers are the difference between "idle because healthy" and
"idle while work piles up". Neither the adapter nor any shibuya-family component queries
`pgmq.metrics()` today (audited 2026-08-19 at commit `fee9b3a`, re-confirmed at filing time).

The initiative's layering rule shapes *how* this should be built: overlaps resolve toward the
lower layer, and queue mechanics are owned by pgmq-hs. keiro-ui has filed the matching requests
there — `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-3` (a `pgmq-metrics`
sister package serving queue metrics over HTTP) on top of
`mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-1` (non-destructive reads) and
`mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-2` (JSON codecs). What pgmq-hs
cannot know is the *binding*: which processor consumes which queue. That binding is this
adapter's knowledge, and exposing it — joined with queue numbers sourced from pgmq-owned
surfaces — is what this request asks for.

## Requested Change

1. Expose, for each configured queue binding, the queue's depth (total and visible,
   distinguished per pgmq-hs's `docs/design/002-queue-visible-length.md` semantics) and
   oldest-message age, associated with the `ProcessorId` that consumes it.
2. Source those numbers from pgmq-owned surfaces: the pgmq-hs observability API
   (`queueMetrics`/`allQueueMetrics`) in-process, or the future `pgmq-metrics` endpoints
   (pgmq-hs IR-3) out-of-process. Direct `pgmq.metrics($1)` SQL from the adapter is acceptable
   only as an interim in-process source and only through pgmq-hs's own client API — the
   adapter must not hand-write SQL against `pgmq.*` tables.
3. Expose the binding-plus-context data wherever the adapter can reach an inspection surface:
   at minimum as a queryable API on the adapter (so a host or a shibuya-metrics extension can
   serve it); an HTTP exposure is welcome but its wire format must follow the cross-project
   conventions (project `mori://shinzui/keiro-ui`, path
   `docs/architecture/inspection-api-conventions.md`, artifact-level URI pending).
4. Document the polling cost honestly: pgmq's `metrics_all()` is O(number of queues) with
   per-queue `count(*)` scans, so per-binding `metrics($1)` calls or a documented poll
   interval are the expected shape.

## Acceptance

1. With a processor consuming a queue holding N ready messages in a test database, the
   adapter's context surface reports that queue's depth (total and visible labeled distinctly)
   and a growing oldest-message age, associated with the correct `ProcessorId`.
2. When the queue drains, the reported depth reaches zero without restarting anything.
3. The implementation contains no hand-written SQL against `pgmq.*` tables — verifiable by
   inspection — and goes through pgmq-hs client APIs (or pgmq-owned endpoints) exclusively.
4. A processor bound to a queue that pgmq reports errors for (dropped mid-run) yields a
   structured error in the context surface, not a crash of the processor loop.

## Requested Deliverables

The binding-context API with tests against the adapter's real-database test harness,
documentation including the polling-cost caveat, and — if HTTP exposure is included — wire
shapes following the cross-project conventions.
