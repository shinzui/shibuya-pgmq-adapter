---
type: Bug Report
title: Long polls can starve acknowledgements on a shared pool
description: >-
  Two long-polling processors sharing a two-connection pool run their handlers but
  defer AckOk and transactional dead-letter acknowledgement until shutdown.
generated:
  by: process:claude-code
  at: "2026-09-30T20:54:15Z"
bugId: BUG-1
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter
capability: mori://shinzui/shibuya-pgmq-adapter/okf/capabilities/concepts/CAP-1
affectedVersion: "0.16.1.0"
environment: >-
  Historical adapter 0.16.0.0 with Shibuya core 0.9.0.3 and current Hackage
  adapter 0.16.1.0 with Shibuya core 0.10.0.0 on PostgreSQL 17 and 18; also the
  pinned remediation adapter checkout on PostgreSQL 18. Two processors use
  LongPolling 5 100 and share a Hasql pool of size two.
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
0 and 0 and the dead-letter rows are 1. No message loss was observed.

The isolated Hackage adapter 0.16.1.0 package lane passed 33 package examples,
then executed the same scenario body on PostgreSQL 17 and 18 through
`mori://shinzui/keiro-runtime-kenshou` at
`kenshou-shibuya/test/Main.hs` (artifact-level URI pending) with
`--pgmq-live-probe`. Both live runs reported only `acknowledgement-deadline`,
with handler calls 1 and 1, pre-shutdown source rows 1 and 1, DLQ rows 0, two
active long polls, and post-shutdown source rows 0 and 0 with DLQ rows 1. This
focused package-lane probe does not produce a sealed full-CLI run result.

The two active long polls suggest connection occupancy is involved, but the
probe does not isolate the scheduling or pool-acquisition mechanism. A fix
needs a live regression that preserves acknowledgement progress while both
long polls are active.

## Root cause

The keiro repository (`mori://shinzui/keiro`) isolated the mechanism while tracing its
own reports `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-6` (six long-polling
processors stall on a three-connection pool) and
`mori://shinzui/keiro/okf/bug-reports/concepts/BUG-4` in
`mori://shinzui/keiro/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6`.
`LongPolling maxSec intervalMs` makes `pgmqChunks` in
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` call `readWithPoll` (or a
grouped `*WithPoll` variant), which is one `pgmq.read_with_poll` statement that loops on
the PostgreSQL server for up to `maxSec` seconds and holds its pool connection for the
whole call. Every `Pgmq` operation is a separate `Hasql.Pool.use`, so during that call
the connection is unavailable to anything else. Shibuya's supervised runner
(`mori://shinzui/shibuya` at `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`,
`runIngesterAndProcessor`) polls on an ingester thread that issues the next read as soon
as it has handed a message to the inbox, so a processor whose handler is running still
holds a connection inside a server-side loop. With N long-polling processors on a pool of
N connections every connection is pinned; `AckOk`'s `deleteMessage`, the
`deadLetterTransactionally` transaction, and any handler database work on the same pool
wait in `Hasql.Pool.use` until a loop returns. hasql-pool's `use` (`mori://hasql/hasql` at
`hasql-pool/src/library/exposed/Hasql/Pool.hs`) wakes every STM waiter at once with no
first-come-first-served order, and the ingester that just returned a connection asks for
it again immediately, so the acknowledgement usually loses the race and eventually hits the
acquisition timeout; `pgmq-effectful` classifies that as transient and the handle retries
into the same contention. Acknowledgements complete at shutdown because
`Adapter.shutdown` stops the ingesters and the connections finally drain. keiro's
six-processor arm (Kenshou run `01a0d52d-8a1e-7070-be94-b20e771f6650`, worker control
log) shows the same shape with handler work instead of an acknowledgement: one delivery,
then no effect for thirty seconds while three backends sat in `read_with_poll`.

## Recommended remedy

Implement `LongPolling` in the client process and stop issuing `read_with_poll` and its
grouped variants; see the remedy section of
[BUG-4](long-poll-outlives-a-killed-client-and-consumes-a-read-attempt.md), which the same
server-side loop causes. A client-side loop that reads once, sleeps `pollIntervalMs`, and
gives up after `maxPollSeconds` performs the same one `UPDATE` per interval as the server
loop, keeps `PollingConfig` unchanged, and never holds a connection between reads, so a
two-connection pool serves two long-polling processors and their acknowledgements. A
regression for this report is the Kenshou schedule in one test: two `LongPolling 5 100`
processors on a two-connection pool, one message on each queue, and both acknowledgements
(source rows 0, dead-letter row 1) observed within a few seconds while the application is
still running. Enlarging the pool only moves the threshold and is not a fix.

