---
type: Bug Report
title: A server-side long poll outlives its killed client and consumes a read attempt
description: >-
  LongPolling issues pgmq.read_with_poll, which keeps looping on the PostgreSQL server
  after the worker process dies and charges the next visible message a read attempt
  that no handler ever sees.
generated:
  by: process:claude-code
  at: "2026-09-30T20:53:44Z"
bugId: BUG-4
status: reported
severity: degraded
origin: mori://shinzui/keiro
affects: mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter
capability: mori://shinzui/shibuya-pgmq-adapter/okf/capabilities/concepts/CAP-1
affectedVersion: "0.16.1.0"
environment: >-
  Adapter 0.16.1.0 with Shibuya core 0.10.0.0, consumed through keiro-pgmq 0.17.0.0,
  on durable PostgreSQL 18. Two worker processes read one queue with
  LongPolling 5 100, a three-second visibility timeout, and maxRetries 3; the
  process holding each delivery is killed with SIGKILL while its handler runs.
observed: >-
  After each kill the dead process's PostgreSQL backend kept executing
  pgmq.read_with_poll, read the message again when its visibility timeout expired,
  committed the read_ct increment and the new vt, and only then failed with
  "could not send data to client: Broken pipe" and "connection to client lost".
  The surviving worker received attempt 2 directly after attempt 0, or the message
  reached the dead-letter queue with read_count 5 after three handler calls.
expected: >-
  A read attempt is charged only when a live consumer receives the message. After a
  worker process dies, nothing it started keeps reading on its behalf, so three
  killed deliveries under maxRetries 3 produce handler attempts 0, 1, and 2 followed
  by a dead-letter move at read_count 4.
reproduction:
  - Create a queue on PostgreSQL 18 and send one message with a two-second delay so it is invisible at first.
  - From a separate client process (for example psql), run SELECT msg_id FROM pgmq.read_with_poll('<queue>', 30, 1, 10, 100) and kill that process with SIGTERM or SIGKILL after 300 milliseconds.
  - Half a second later, pg_stat_activity still shows the backend active in read_with_poll; three seconds after the send, the queue row has read_ct 1 and a vt thirty seconds in the future although no client received it.
  - The end-to-end form is the keiro scenario keiro/queue/concurrency/crash-redelivery-cadence with queue.polling=long-poll in mori://shinzui/keiro-runtime-kenshou, whose PostgreSQL log times each backend's client-lost FATAL at the visibility timeout after the delivery it orphaned.
workaround: >-
  Select StandardPolling. A killed process then leaves at most one millisecond-scale
  pgmq.read in flight, and the poll-every control of the same keiro scenario passes.
---

# A server-side long poll outlives its killed client and consumes a read attempt

`pgmq.read_with_poll` is a PL/pgSQL loop: every `poll_interval_ms` it runs the same
`UPDATE ... SET vt = ..., read_ct = read_ct + 1 ... FOR UPDATE SKIP LOCKED` that
`pgmq.read` runs, returns as soon as it finds rows, and otherwise calls `pg_sleep`
until `max_poll_seconds` elapse (`mori://pgmq/pgmq` at
`pgmq-extension/sql/pgmq.sql`, function `read_with_poll`; artifact URI pending). The
whole call is one statement on one connection. PostgreSQL notices a closed client
socket only when a backend reads from or writes to it, and a backend inside this loop
does neither until the function returns. When the client process dies, the loop keeps
running for the rest of its budget; if a message becomes visible in that window the
loop reads it, the implicit transaction commits, and the backend fails only when it
flushes the result. The read attempt is spent and no consumer has the message.

The adapter reaches that statement from `pgmqChunks` in
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`: `LongPolling maxSec
intervalMs` calls `readWithPoll`, and the grouped variants call
`readGroupedWithPoll`, `readGroupedRoundRobinWithPoll`, and
`readGroupedHeadWithPoll`. Shibuya's supervised runner (`mori://shinzui/shibuya` at
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`, `runIngesterAndProcessor`)
runs the adapter source on an ingester thread that issues the next poll as soon as it
has handed a message to the inbox, so a processor whose handler is running always has
another server-side loop in flight. A kill during the handler therefore orphans a loop
whose remaining budget (five seconds) exceeds the visibility timeout (three seconds) of
the message the handler was holding, and the orphan re-reads that very message.

## Evidence

The keiro repository (`mori://shinzui/keiro`) reports this as
`mori://shinzui/keiro/okf/bug-reports/concepts/BUG-4` and traced it in
`mori://shinzui/keiro/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6`
from Kenshou run artifacts (`mori://shinzui/keiro-runtime-kenshou` at `runs/<run-id>/`;
artifact-level URIs pending). In run `01a0d1b4-5232-707b-abed-404ce0d0db3e`, worker 0
reported attempt 0 at `04:37:31.823 UTC` and was killed; its backend (pid 77243) logged
the broken pipe at `04:37:34.889 UTC`, 3.07 seconds later, short of the five-second
budget, so the loop ended because it found a row. Worker 1 then reported attempt 2 at
`04:37:37.986 UTC`. In run `01a0d1b3-8a6c-7624-aa6f-7fff066f8787` the first two orphans
lost the race to live workers and died at the full 5.02-second budget, but the third
(pid 76149) died 3.07 seconds after attempt 2; the dead-letter wrapper then recorded
`read_count 5` after three handler calls. The `StandardPolling` control runs passed.

## Recommended remedy

Implement `LongPolling` in the client process and stop issuing `read_with_poll` and
its grouped variants. In `pgmqChunks`, replace each `LongPolling maxSec intervalMs`
branch with a loop that issues the corresponding single read (`readMessage`,
`readGrouped`, `readGroupedRoundRobin`, or `readGroupedHead`), returns on the first
non-empty result, and otherwise sleeps `intervalMs` and reads again until `maxSec`
seconds have elapsed on a monotonic clock, returning empty. This keeps
`PollingConfig`'s public shape and `maxPollSeconds`' meaning (a poll returns within
that bound), performs the same one `UPDATE` per interval the server loop performed,
and releases the pool connection between reads, which also removes the mechanism
behind BUG-1. `mkReadWithPoll` and `mkReadGroupedWithPoll` become unused and the
`InternalSpec` FIFO dispatch cases for long polling should expect the standard read
operations and reject any `*WithPoll` operation. A regression can spawn and kill a
`psql` client as in the reproduction, and an app-level test can assert that
`pg_stat_activity` never shows `read_with_poll` while a `LongPolling` adapter runs.
Setting PostgreSQL's `client_connection_check_interval` on pool connections is not a
substitute: it exists only on PostgreSQL 14 or later, works on a subset of operating
systems, and does nothing about the connection pinning in BUG-1.

keiro-pgmq no longer selects the adapter's `LongPolling` mode after its plan 300; the
adapter fix protects every other consumer of `PollingConfig`.
