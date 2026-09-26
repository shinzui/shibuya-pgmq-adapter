---
type: Bug Report
title: Long polls can starve acknowledgements on a shared pool
description: >-
  Two long-polling processors sharing a two-connection pool run their handlers but
  defer AckOk and transactional dead-letter acknowledgement until shutdown.
generated:
  by: openai/codex
  at: "2026-09-26T02:05:00Z"
bugId: BUG-1
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter
capability: mori://shinzui/shibuya-pgmq-adapter/okf/capabilities/concepts/CAP-1
affectedVersion: "0.16.0.0"
environment: >-
  Historical adapter 0.16.0.0 with Shibuya core 0.9.0.3 on PostgreSQL 17 and
  18, and the pinned remediation adapter checkout on PostgreSQL 18. Two
  processors use LongPolling 5 100 and share a Hasql pool of size two.
observed: >-
  Both handlers ran once, but after 25 seconds both source queues still held one
  row, the dead-letter queue had no row, and PostgreSQL reported two active
  pgmq.read_with_poll calls. After stopAppGracefully, both source rows were gone
  and one dead-letter row existed. The onAckFailure hook was not called.
expected: >-
  The published CAP-1 acknowledgement decisions should complete while the
  application is running, even when the configured pool size equals the number
  of long-polling processors. AckOk should delete its source row, and
  AckDeadLetter should transactionally move its source row to the dead-letter
  queue without requiring shutdown.
reproduction:
  - Create two source queues and one direct dead-letter queue on PostgreSQL 17 or 18.
  - Start two pgmqAdapter processors using LongPolling 5 100 and one shared Hasql pool with two connections; have one handler return AckOk and the other return AckDeadLetter.
  - Wait until pg_stat_activity shows two active pgmq.read_with_poll calls, then send one message to each source queue from a separate producer pool.
  - Observe that both handlers run once but the two source rows remain and the dead-letter row is absent for 25 seconds; stop the application and observe the queued acknowledgements then complete.
workaround: >-
  Use a larger consumer pool than the number of concurrent long-polling
  processors, or select standard polling. These configurations have not yet
  been verified by this reproduction and require a dedicated regression check.
---

# Long polls can starve acknowledgements on a shared pool

The external verification scenario
`mori://shinzui/keiro-runtime-kenshou` at
`shibuya/pgmq-adapter/concurrency/long-poll-pool-starvation` (scenario artifact
URI pending) reproduces the
25-second acknowledgement stall on PostgreSQL 17 and 18 with adapter
0.16.0.0, and on PostgreSQL 18 with the pinned remediation checkout. The
historical PostgreSQL 18 result is in `mori://shinzui/keiro-runtime-kenshou` at
`runs/01a0db70-189a-70d4-9f7c-52aca782b9ec/run-result.json`; the PostgreSQL
17 result is at `mori://shinzui/keiro-runtime-kenshou` path
`runs/01a0db6e-f489-73d1-9ac5-7a37f516cc83/run-result.json`, and the pinned
remediation result is at `mori://shinzui/keiro-runtime-kenshou` path
`runs/01a0db72-69f6-736c-a4d5-88ea1138baf3/run-result.json`
(artifact-level URIs pending). The PostgreSQL 17 probe revision did not
record pre-shutdown row counts, but produced the same timeout and post-shutdown
state.

The SQL oracle uses the separate producer pool, so its reads do not compete
for the consumer pool. In the PostgreSQL 18 run, the pre-shutdown facts are
source rows 1 and 1, dead-letter rows 0, and active long polls 2. The handler
counts are 1 and 1, and `onAckFailure` is 0. After shutdown the source rows are
0 and 0 and the dead-letter rows are 1. No message loss was observed. Current
Hackage adapter 0.16.1.0 has compiled and passed package tests in the external
suite; this live reproduction has not yet run against it.

The two active long polls suggest connection occupancy is involved, but the
probe does not isolate the scheduling or pool-acquisition mechanism. A fix
needs a live regression that preserves acknowledgement progress while both
long polls are active.
