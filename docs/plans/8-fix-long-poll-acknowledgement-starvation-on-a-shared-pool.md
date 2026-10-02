---
id: 8
slug: fix-long-poll-acknowledgement-starvation-on-a-shared-pool
title: "Fix long-poll acknowledgement starvation on a shared pool"
kind: exec-plan
created_at: 2026-09-30T20:51:46Z
intention: "intention_01m3t2qeecekvrdbj2rfy522px"
---

# Fix long-poll acknowledgement starvation on a shared pool

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today an application that runs two long-polling PGMQ processors on a Hasql pool with two
connections delivers every message to its handlers but never finishes acknowledging them.
The `AckOk` delete and the transactional `AckDeadLetter` move wait for a pooled connection
that the polling loops grab back the instant they release it, so both source queues keep
their rows, the dead-letter queue stays empty, and the acknowledgements only complete when
the application shuts down and polling stops. The owning bug report is
[docs/bug-reports/long-polls-starve-acknowledgements-on-a-shared-pool.md](../bug-reports/long-polls-starve-acknowledgements-on-a-shared-pool.md)
(`mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1`), reproduced
externally against adapter 0.16.0.0 and the current Hackage release 0.16.1.0 on PostgreSQL
17 and 18. The same server-side loop is behind the sibling report
[docs/bug-reports/long-poll-outlives-a-killed-client-and-consumes-a-read-attempt.md](../bug-reports/long-poll-outlives-a-killed-client-and-consumes-a-read-attempt.md)
(`mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-4`): a poll that keeps
running inside PostgreSQL after its client process died charges the next visible message a
read attempt that no handler ever sees.

After this plan, `LongPolling maxPollSeconds pollIntervalMs` is implemented in the client
process: the adapter reads once, and if nothing is there it sleeps `pollIntervalMs` and reads
again until `maxPollSeconds` have elapsed, holding a pooled connection only for the
milliseconds of each read. The same two-processor, two-connection configuration then
acknowledges both messages within a fraction of a second while the application is running,
`pg_stat_activity` never shows `pgmq.read_with_poll` for an adapter connection, shutdown no
longer waits for a server-side wait to expire, and a killed process leaves nothing running in
the database on its behalf. A new PostgreSQL-backed regression in the adapter's own suite
proves the acknowledgement behaviour, first by failing against the current code and then by
passing after the fix. Busy-queue throughput is unchanged because a queue with messages
returns on the first read exactly as the server-side loop did; the only cost that changes is
the number of idle round trips (one per `pollIntervalMs` instead of one per
`maxPollSeconds`), which this plan measures, records, and documents together with
`pollIntervalMs` as the knob that controls it. You can see the result by running the adapter
test suite against an ephemeral PostgreSQL and by re-running the external verification
scenario in `mori://shinzui/keiro-runtime-kenshou`.


## Progress

- [ ] M1: Add pool-sizing and oracle helpers to the test fixtures (`withPgmqDbSettings`,
  `createNamedPool`, `withNamedQueue`, `queueRowCount`, `activeLongPolls`, `waitUntil`).
- [ ] M1: Write the shared-pool regression test in `ChaosSpec` and run it against the
  unmodified source; record the failing transcript (rows 1/1/0, two active long polls,
  zero ack-failure hooks at the 15-second deadline) in Surprises & Discoveries.
- [ ] M1: Add the `Bench.AdapterDrain` benchmark (busy drain plus idle cost) and capture the
  pre-fix baseline numbers for it and for the existing `read/poll`, `ack`, and `throughput`
  groups.
- [ ] M1: Set BUG-1 `status: confirmed`, append a bundle log entry, and run strict bug-report
  validation (BUG-4 stays `reported` until its guard exists in M3).
- [ ] M1: Commit fixtures, benchmark, and bug-report confirmation (regression test stays
  uncommitted until M2 so every commit keeps the suite green).
- [ ] M2: Rewrite the long-poll branches of `pgmqChunks` as a client-side loop
  (`pgmqChunksUntil`, `longPoll`), thread the shutdown flag through `pgmqSourceWithShutdown`
  and `pgmqChunksPrefetch`, and delete `mkReadWithPoll` and `mkReadGroupedWithPoll`.
- [ ] M2: Update `InternalSpec` (FIFO dispatch expectations, removed query-constructor specs)
  and add `clientLongPollSpec` (interval spacing, immediate return on messages, deadline,
  stop flag).
- [ ] M2: Run the shared-pool regression and the full suite; record the passing transcript
  and the measured acknowledgement latency.
- [ ] M2: Commit the fix with the regression and unit tests.
- [ ] M3: Add the no-server-side-poll guard, the idle read-cadence guard, and the idle-pickup
  guard to `ChaosSpec`; run them.
- [ ] M3: Re-run the benchmark groups after the fix, compare against the M1 baseline, and
  record both tables in this plan; decide on the documented default guidance for
  `pollIntervalMs` from the idle-cost numbers.
- [ ] M3: Commit the performance guard.
- [ ] M4: Update `Config.hs` haddocks, `docs/pgmq-adapter/CONFIGURATION.md`,
  `docs/pgmq-adapter/INTERNALS.md`, `docs/pgmq-adapter/ARCHITECTURE.md`,
  `docs/pgmq-adapter/README.md`, `docs/user/pgmq-getting-started.md`, and
  `docs/capabilities/consume-pgmq-queue.md`; run `just check-capabilities`.
- [ ] M4: Write `docs/adr/0002-poll-pgmq-client-side-for-long-polling.md`.
- [ ] M4: Add `## Unreleased` entries to both changelogs and commit the documentation.
- [ ] M5: Release through the repository `/release` skill (recommended `minor`, producing
  0.16.2.0; see Decision Log), then set BUG-1 and BUG-4 to `fixed` with `fixedVersion` and
  `resolution`, log them, validate, and commit.
- [ ] M5: Run the external live probe in `mori://shinzui/keiro-runtime-kenshou` against the
  released package and record the outcome here.
- [ ] Fill in Outcomes & Retrospective and complete the ADR distillation pass.


## Surprises & Discoveries

- While this plan was being written (2026-09-30, 20:53 to 20:54 UTC), another Claude Code
  process updated the bug-report bundle: it added BUG-4 and appended a "Root cause" and
  "Recommended remedy" section to BUG-1 that reaches the same mechanism this plan had
  derived independently (connection pinning by `read_with_poll`, an ingester that re-polls
  immediately, and hasql-pool's unordered STM waiters) and recommends the client-side loop.
  Those edits were left uncommitted in the working tree by that process and are not part of
  this plan's commits. The plan's remedy was changed from a post-empty-poll pause to the
  client-side loop as a result; see the Decision Log and the revision note at the end.


## Decision Log

- Decision: Implement `LongPolling` as a client-side loop (read once; if empty, sleep
  `pollIntervalMs` and read again until `maxPollSeconds` have elapsed on a monotonic clock;
  return empty) and stop issuing `pgmq.read_with_poll` and its grouped variants.
  Rationale: The root cause of BUG-1 is that a server-side long poll pins one pooled
  connection per processor for up to `maxPollSeconds`, the ingester re-polls the instant it
  returns the connection, and hasql-pool wakes all STM waiters with no first-come order, so
  an acknowledgement on a saturated pool loses the race until shutdown. A client-side loop
  holds a connection only for the milliseconds of each read, so the pool is free for well
  over ninety-nine percent of an idle interval and any waiter acquires it on its next
  attempt. The same loop is also the only adapter-level fix for BUG-4, because a server-side
  loop that outlives a dead client cannot be stopped from the client. It performs the same
  one `pgmq.read` statement per interval that `read_with_poll` performed inside its loop,
  never holds a transaction open across the wait, lets shutdown interrupt the wait, and keeps
  `PollingConfig` and the meaning of both fields unchanged. This is the remedy the owning
  bug reports recommend and the one keiro already adopted for its own workers in
  `mori://shinzui/keiro/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6`.
  Date: 2026-09-30

- Decision: Reject the alternative of keeping `read_with_poll` and sleeping `pollIntervalMs`
  on the client after an empty poll.
  Rationale: That pause would resolve BUG-1's starvation (the poll thread would be blocked
  while the connection is free) but with a residual acknowledgement latency of up to
  `maxPollSeconds` whenever the pool has no spare connection, a shutdown that still waits for
  the server-side wait to expire, and no effect on BUG-4. Fixing BUG-4 later would replace
  the same code again. The pause was this plan's first draft; it is recorded here so nobody
  re-derives it as the cheaper option without seeing why it was set aside.
  Date: 2026-09-30

- Decision: Reject a pending-acknowledgement priority gate or a fair first-in-first-out gate
  in front of the pool, a dedicated acknowledgement pool, and changes to hasql-pool.
  Rationale: A pool-wide gate needs state shared by every processor on the same pool, which
  the adapter cannot key without an API change, and a fair semaphore needs the pool size,
  which hasql-pool does not expose. A separate acknowledgement pool is a configuration
  workaround. Fair acquisition inside hasql-pool is third-party work and would still leave
  the connection pinned for the whole wait. None of them addresses BUG-4.
  Date: 2026-09-30

- Decision: The idle cost is measured, recorded, and documented rather than assumed away,
  and `pollIntervalMs` is documented as the knob that sets it.
  Rationale: The only footprint that grows is the number of idle round trips per processor,
  from one per `maxPollSeconds` to one per `pollIntervalMs`. Each round trip carries the
  same `pgmq.read` statement the server-side loop already ran each interval, so database
  statement work is unchanged; what is added is protocol overhead and a pool
  acquire/release per check. The `adapter-drain` benchmark's `idle-cost` entries quantify
  client CPU, backend CPU, and read count for eight idle processors at 100 ms and 1000 ms,
  and the acceptance in Validation is an explicit budget. If the budget is missed at 100 ms,
  the documented guidance changes, not the design.
  Date: 2026-09-30

- Decision: A long poll also stops waiting when the adapter's shutdown flag is set, through
  a new `pgmqChunksUntil :: IO Bool -> PgmqAdapterConfig -> Stream ...` used by the adapter
  source; `pgmqChunks config` remains as `pgmqChunksUntil (pure False) config` for internal
  callers and tests.
  Rationale: With the wait on the client, checking the flag between reads costs one
  `readTVarIO` and removes the documented "may delay shutdown by up to maxPollSeconds"
  trade-off. The gate in `pgmqSourceWithShutdown` still decides whether a chunk is kept and
  still releases just-read messages; the flag merely shortens the wait.
  Date: 2026-09-30

- Decision: The regression test uses a two-connection consumer pool with a ten-second
  acquisition timeout, a separate oracle pool, `LongPolling 5 100`, and a fifteen-second
  acknowledgement deadline.
  Rationale: This mirrors the external scenario (two processors, pool size two, `AckOk` and
  `AckDeadLetter`, oracle traffic on a different pool) so the in-repo test validates the same
  defect. A ten-second acquisition timeout keeps the pre-fix failure mode simple (the
  acknowledgement is still blocked at the deadline rather than mid-backoff). Fifteen seconds
  is three poll durations: far above the expected sub-second latency after the fix and well
  below the twenty-five-second external deadline, so the test fails quickly on the current
  code.
  Date: 2026-09-30

- Decision: Capture a benchmark baseline before touching `Internal.hs`, and guard performance
  with the existing `read/poll`, `ack`, and `throughput` groups, a new end-to-end
  `adapter-drain` benchmark (busy drain under standard and long polling, and idle cost), and
  three `ChaosSpec` guards (no server-side poll, idle read cadence, idle pickup latency).
  Rationale: The busy path must show no change; the idle path must show the interval is
  honoured (no busy loop), the pickup bound is kept, and `read_with_poll` is gone. The user
  asked explicitly that no performance degradation be introduced; the evidence is recorded
  in this plan rather than asserted.
  Date: 2026-09-30

- Decision: BUG-4 is closed by this plan as a consequence of the chosen remedy, with the
  application-level guard (no `read_with_poll` in `pg_stat_activity` while a `LongPolling`
  adapter runs) as its evidence; the process-kill reproduction is an optional extra.
  Rationale: The adapter-level fix for BUG-4 is exactly "never issue `read_with_poll`",
  which the guard proves directly. Reproducing the orphaned-loop symptom requires killing a
  separate operating-system client, which is PGMQ behaviour rather than adapter behaviour;
  it is described as an optional `psql`-based check for completeness.
  Date: 2026-09-30

- Decision: Recommend releasing as 0.16.2.0 (a PVP minor bump) rather than 0.16.1.1.
  Rationale: Under the PVP a bug fix with no API change is a patch. However the external
  verification scenario in `mori://shinzui/keiro-runtime-kenshou` already classifies the
  defect as `VersionBelow "shibuya-pgmq-adapter" "0.16.2.0"`, and the release changes the
  documented behaviour of `LongPolling` (no server-side wait, prompt shutdown, idle cadence).
  Publishing 0.16.2.0 keeps the external cohort's expectation truthful without a coordinated
  change there. The release skill is user-invoked; this plan records the recommendation and
  the final level is confirmed at release time.
  Date: 2026-09-30

- Decision: Move BUG-1 to `confirmed` as soon as the in-repo regression reproduces the
  stall, and move BUG-1 and BUG-4 to `fixed` only after the fixing version is published.
  Rationale: The bug-report profile defines `confirmed` as "the owning repository
  reproduced it" and demands `fixedVersion` and `resolution` once a report is `fixed`. The
  fixing version does not exist until the release step, so the terminal transitions belong to
  M5.
  Date: 2026-09-30

- Decision: This plan changes only this repository. It does not modify hasql-pool,
  pgmq-effectful, shibuya-core, or keiro.
  Rationale: The adapter-local loop fully resolves both reports. `pgmq-effectful` keeps
  exporting `readWithPoll` and the grouped variants for other consumers; the adapter simply
  stops calling them.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What the repository is

This repository is a Cabal workspace with three packages. `shibuya-pgmq-adapter` is the
published library: it turns a PGMQ queue (a message queue implemented as PostgreSQL tables and
functions) into an adapter for Shibuya, a supervised queue-processing framework. The
`shibuya-pgmq-adapter-bench` package holds `tasty-bench` benchmarks and an endurance
executable; `shibuya-pgmq-example` is a runnable example. Only the library is released to
Hackage. The workspace is built with `cabal build all` from the repository root inside the
Nix development shell (`direnv` loads it), formatted with `nix fmt` (fourmolu), and tested
with `cabal test shibuya-pgmq-adapter-test --enable-tests` (also `just test`). The test suite
is compiled with `-threaded -with-rtsopts=-N`. Database-backed tests start an ephemeral
PostgreSQL through the `ephemeral-pg` library and install the PGMQ schema with
`pgmq-migration`; setting `PGMQ_TEST_SKIP_DB=1` marks them pending. Benchmarks need a
running server reachable through `PG_CONNECTION_STRING`, which the dev shell exports and
`just process-up` serves.

### The four source modules

The library is four modules under `shibuya-pgmq-adapter/src/Shibuya/Adapter/`:

`Pgmq.hs` is the public surface. `pgmqAdapter env config` validates the configuration and
returns an `Adapter` whose `source` is a Streamly stream of `Ingested` messages built by
`pgmqSourceWithShutdown`, and whose `shutdown` sets a `TVar`. The stream is
`chunkStream & takeWhileM keepChunk & filter (not . null) & unfoldEach uncons & mapMaybeM
(mkIngested env config)`: chunks (one PostgreSQL read each) are gated on shutdown, empty
chunks are dropped, chunks are flattened to messages, and each message becomes an
`Ingested` with an acknowledgement handle and a lease. `chunkStream` is `pgmqChunks config`
without prefetch and `pgmqChunksPrefetch (maxBuffer n) config` with it.

`Pgmq/Config.hs` holds `PgmqAdapterConfig` and `PgmqAdapterEnv`. The environment carries the
Hasql `Pool` plus two callbacks, `onAutoDeadLetter` and `onAckFailure`; `mkPgmqAdapterEnv
pool` builds it with no-op callbacks. `PollingConfig` is either `StandardPolling
{pollInterval}` or `LongPolling {maxPollSeconds, pollIntervalMs}`. `validateConfig` rejects
`maxPollSeconds < 1` and `pollIntervalMs < 1`.

`Pgmq/Internal.hs` implements polling and acknowledgement. `pgmqChunks config` is
`Stream.repeatM (retryingTransient config.pollRetry poll)`. In standard polling, `poll`
calls `readMessage` (or `readGrouped`, `readGroupedRoundRobin`, `readGroupedHead` for FIFO
strategies) and sleeps `pollInterval` when the result is empty. In long polling, it calls
`readWithPoll` (or `readGroupedWithPoll`, `readGroupedRoundRobinWithPoll`,
`readGroupedHeadWithPoll`), built by `mkReadWithPoll` and `mkReadGroupedWithPoll`, and
returns whatever came back. `mkAckHandle` runs the decision under `retryingTransient
config.ackRetry`: `AckOk` deletes through the `Pgmq` effect, `AckRetry` and `AckHalt` change
the visibility timeout, and `AckDeadLetter` with a configured dead-letter target calls
`deadLetterTransactionally`, which runs one `ReadCommitted` write transaction directly
through `Pool.use env.pool`. `mkLease` renews leases through `setVisibilityTimeoutAt`.
`retryingTransient` retries errors for which `isTransient` holds, up to `maxAttempts`
(default five) with exponential backoff from `initialBackoff` (default 0.1 s) capped at
`maxBackoff` (default 5 s). `releaseMessages` resets visibility on shutdown.
`pgmqChunksPrefetch` wraps `pgmqChunks` in Streamly's `parBuffered` under a locally scoped
`ConcUnlift` strategy.

`Pgmq/Convert.hs` maps PGMQ messages to Shibuya envelopes and builds dead-letter payloads. It
is not touched by this plan.

### The dependencies that matter

The `Pgmq` effect and its interpreter come from `pgmq-effectful`
(`mori://shinzui/pgmq-hs/packages/pgmq-effectful`, local corpus 0.6.1.1, bound `^>=0.6`).
`runPgmq pool` interprets every operation as `Pool.use pool session`. Its
`fromUsageError` maps hasql-pool's `AcquisitionTimeoutUsageError` to
`PgmqAcquisitionTimeout`, and `isTransient PgmqAcquisitionTimeout` is `True`, so an
acknowledgement that cannot get a connection is retried by `retryingTransient`.

The pool comes from `hasql-pool` (`mori://hasql/hasql`, local corpus 1.4.2, bound `^>=1.4`).
Its `use` function is the mechanism at the heart of this bug and is reproduced here from
`hasql-pool/src/library/exposed/Hasql/Pool.hs` so the reader does not need the corpus:

```haskell
use Pool {..} sess = do
  timeout <- do
    delay <- registerDelay poolAcquisitionTimeout
    return $ readTVar delay
  join . atomically $ do
    reuseVar <- readTVar poolReuseVar
    asum
      [ readTQueue poolConnectionQueue <&> onConn reuseVar,
        do
          capVal <- readTVar poolCapacity
          if capVal > 0
            then do
              writeTVar poolCapacity $! pred capVal
              return $ onNewConn reuseVar
            else retry,
        do
          timedOut <- timeout
          if timedOut
            then return . return . Left $ AcquisitionTimeoutUsageError
            else retry
      ]
```

A caller that finds no idle connection and no capacity blocks in `retry`. Returning a
connection is `writeTQueue poolConnectionQueue entry`. There is no queue of waiters: when an
entry is written, every blocked caller becomes runnable and whichever one commits its
transaction first takes the connection. A thread that is *not* blocked but calls `use` right
after the write competes on equal terms. The default acquisition timeout is ten seconds.

Shibuya core (`mori://shinzui/shibuya/packages/shibuya-core`, 0.10.0.0, bound
`^>=0.10.0.0`) runs each processor as an ingester thread that drains the adapter stream into a
bounded inbox (default size 100) and a processor loop that runs the handler and then the
acknowledgement on its own thread through `finalizeWithRetry`, which retries a throwing
finalizer three times (10 ms, 50 ms, 250 ms). So polling and acknowledging run concurrently
and both need the same pool.

PGMQ's `read_with_poll` is a PL/pgSQL function that loops inside one transaction: it runs the
same locking `UPDATE ... FOR UPDATE SKIP LOCKED` that `pgmq.read` runs, returns immediately if
rows were leased, otherwise calls `pg_sleep` for `poll_interval_ms` and retries until
`max_poll_seconds` has elapsed, then returns an empty set. The connection is `active` in
`pg_stat_activity` for the whole wait; that is the "two active `pgmq.read_with_poll` calls"
the bug report observed. Because the backend neither reads nor writes its socket during the
loop, it does not notice a dead client until the function returns (BUG-4).

### The mechanism, step by step

Take the reported configuration: two processors, each `LongPolling 5 100`, one pool of size
two, one message sent to each queue after both polls are active.

1. Both poll loops hold one connection each inside `read_with_poll`. The pool has no idle
   connection and no capacity.
2. The message arrives; processor A's `read_with_poll` returns it within 100 ms. `runPgmq`
   returns the connection to the queue and control comes straight back to `Stream.repeatM`,
   which calls `readWithPoll` again. Nothing in that path blocks, so the poll thread reaches
   the next `Pool.use` and takes the connection it just released. The queue is now empty
   (the message is invisible), so this poll holds the connection for the full five seconds.
3. Meanwhile the ingester hands the message to the inbox, the handler runs and returns
   `AckOk`, and the processor thread calls `deleteMessage`, which calls `Pool.use` and
   blocks in `retry`. Processor B does the same with `AckDeadLetter`, whose
   `deadLetterTransactionally` also calls `Pool.use`.
4. Five seconds later A's poll returns empty. Its connection is written back to the queue,
   which makes the blocked acknowledgement runnable, but the poll thread is already running
   and immediately calls `Pool.use` again. On the same capability the acknowledgement thread
   cannot run before the poll thread blocks, and the poll thread only blocks once it is inside
   the next `read_with_poll` foreign call, after the connection is taken. On another
   capability the acknowledgement thread must first be woken through the run-time system's
   inter-capability message, which takes longer than the poll thread's few microseconds of
   straight-line code. The poll wins; the same happens with B.
5. The acknowledgement's `Pool.use` eventually hits its acquisition timeout and returns
   `AcquisitionTimeoutUsageError`, which becomes the transient `PgmqAcquisitionTimeout`.
   `retryingTransient` sleeps its backoff and calls `Pool.use` again, re-entering the same
   losing race. With the external scenario's five-second acquisition timeout, one
   `retryingTransient` budget is 5 × 5 s plus 0.1 + 0.2 + 0.4 + 0.8 s of backoff, about
   26.5 s; only then is `PgmqAcknowledgementException` thrown and `onAckFailure` called.
   That is why the external run saw zero hook calls at its 25-second deadline. Shibuya then
   retries the finalizer three more times, so the processor would stay stuck for minutes
   before reporting a lifecycle failure. With the default ten-second timeout the budget is
   about 51.5 s per attempt.
6. `stopAppGracefully` sets the shutdown `TVar`. Each poll loop finishes its current
   `read_with_poll`, observes the gate in `keepChunk`, and ends the stream without polling
   again. Connections stay idle, the next acknowledgement attempt acquires one, and both
   messages are acknowledged, exactly the post-shutdown state the report describes.

Standard polling does not suffer from this because `readMessage` holds a connection for one
round trip and the loop then sleeps `pollInterval` with no connection held; a waiter wins
easily. The fix makes long polling work the same way.

### The fix, in one paragraph

`pgmqChunks` gains a sibling `pgmqChunksUntil stopWaiting config`. Each poll selects one
single-read operation from `fifoConfig` (`readMessage`, `readGrouped`,
`readGroupedRoundRobin`, or `readGroupedHead`) and then applies the waiting policy from
`polling`. `StandardPolling` is unchanged. `LongPolling maxSec intervalMs` becomes a
client-side loop: read once; if the result is non-empty return it; otherwise, if
`stopWaiting` reports true or the next check would land after `maxSec` seconds from the
start (measured with `GHC.Clock.getMonotonicTime`), return the empty result; otherwise sleep
`intervalMs` and read again. `pgmqSourceWithShutdown` passes `readTVarIO shutdownVar` as
`stopWaiting` (also through `pgmqChunksPrefetch`), and `pgmqChunks config` is
`pgmqChunksUntil (pure False) config`. `mkReadWithPoll` and `mkReadGroupedWithPoll` are
deleted along with the `readWithPoll`, `readGroupedWithPoll`,
`readGroupedRoundRobinWithPoll`, and `readGroupedHeadWithPoll` imports. Each check is one
`pgmq.read` (or grouped read) statement, the same statement the server-side loop executed
per interval, so database work per interval is unchanged; a connection is held only during
the read, so a two-connection pool serves two long-polling processors, their
acknowledgements, lease renewals, and dead-letter moves; a busy queue returns on the first
read exactly as before; pickup latency for a message arriving during a sleep is bounded by
`intervalMs` exactly as the server-side check interval was; shutdown interrupts the wait
within one interval; and nothing keeps running in PostgreSQL after the client dies.

### Terms used in this plan

A *pool* is a fixed-size set of PostgreSQL connections handed out one at a time by
`Hasql.Pool.use`. A *long poll* is a wait for messages bounded by `maxPollSeconds`; before
this plan it was one call to `pgmq.read_with_poll` waiting inside the database, after it a
client-side loop of single reads. An *acknowledgement* is the adapter's database action for
a handler's `AckDecision` (`AckOk` deletes, `AckRetry` and `AckHalt` change visibility,
`AckDeadLetter` archives or moves). The *finalizer* is the `AckHandle.finalize` function
Shibuya calls with that decision. *Starvation* means a waiter that is always runnable but
never scheduled onto the resource it needs. A *capability* is one of the operating-system
threads GHC's run-time system uses to run Haskell threads; the test suite runs with as many
as there are cores. An *oracle* is a database connection used only by the test to observe
state, kept on a separate pool so it cannot influence the pool under test. A *round trip* is
one request and response between the client process and PostgreSQL.

### External evidence

The external verification project `mori://shinzui/keiro-runtime-kenshou` reproduces the stall
in scenario `shibuya/pgmq-adapter/concurrency/long-poll-pool-starvation`, whose source is
`kenshou-shibuya/src/Kenshou/Suite/Shibuya/Concurrency/PgmqPoolStarvation.hs` and whose
fixture is `kenshou-shibuya/src/Kenshou/Suite/Shibuya/Fixture/Pgmq.hs` in that repository
(artifact-level URIs pending). Its finding is
`docs/findings/15-shibuya-pgmq-long-poll-pool-starvation.md` there. The scenario builds one
`PgmqAdapterEnv` from a two-connection pool with a five-second acquisition timeout and
application name `kenshou-shibuya-pgmq`, runs both processors under one `runPgmq`, sends
through a separate producer pool, and counts active long polls with:

```sql
select count(*) from pg_stat_activity
where pid <> pg_backend_pid()
  and application_name = 'kenshou-shibuya-pgmq'
  and state = 'active'
  and query like '%pgmq.read_with_poll%'
```

The scenario's `knownDefect` applies to `VersionBelow "shibuya-pgmq-adapter" "0.16.2.0"` and
expects the single failure label `acknowledgement-deadline`. It can be run in isolation with
`cabal --project-file=cohort/shibuya-current.project run kenshou-shibuya-test -- --pgmq-live-probe 18`
from that repository's root (`17` for PostgreSQL 17), given that project's PostgreSQL
environment.

BUG-4's evidence lives in keiro (`mori://shinzui/keiro`, its own
`mori://shinzui/keiro/okf/bug-reports/concepts/BUG-4` and
`mori://shinzui/keiro/okf/bug-reports/concepts/BUG-6`) and was traced in
`mori://shinzui/keiro/plans/300-poll-pgmq-client-side-for-long-poll-job-workers-to-fix-bug-4-and-bug-6`,
which moved keiro's own workers to a client-side loop. Its standalone reproduction runs
`select msg_id from pgmq.read_with_poll('<queue>', 30, 1, 10, 100)` from `psql`, kills
`psql` after 300 ms, and observes that the backend keeps running and later charges a read
attempt.

### Architecture Decision Records consulted

The local ADR corpus is `docs/adr/` with plain Markdown files and no OKF profile. The only
record, [docs/adr/0001-idempotent-dead-letter-moves.md](../adr/0001-idempotent-dead-letter-moves.md),
is relevant: it establishes that dead-letter moves claim the source row inside one
`ReadCommitted` transaction run through `Pool.use env.pool`, that acknowledgement handles are
serialized per handle, and that exhausted acknowledgement errors surface as
`PgmqAcknowledgementException` after `onAckFailure`. This plan keeps all of that; it only
changes how the polling loop waits. A new ADR 0002 will record the polling decision. Across
repositories, Shibuya core's
`docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md` under
`mori://shinzui/shibuya` (artifact-level URI pending; that corpus is not an OKF bundle)
explains that exhausted framework-owned finalization throws `ProcessorFailure`, which is why
a starved acknowledgement eventually becomes a lifecycle failure rather than a silent loss.
The bug-report bundle at `docs/bug-reports/` is profile-governed
(`coordination.bugReports` from okf-profiles v0.18.0); its status vocabulary is `reported`,
`confirmed`, `in-progress`, `fixed`, `wont-fix`, `duplicate`, `not-a-bug`, and
`cannot-reproduce`, with `fixedVersion` and `resolution` required once `fixed`.


## Plan of Work

### Milestone 1: reproduce the stall in this repository and capture baselines

Scope: make the defect observable with the adapter's own test suite, prove the mechanism with
an oracle, record performance baselines before any source change, and confirm the bug report.
At the end, `ChaosSpec` has a shared-pool regression that fails against the current code with a
transcript naming the stalled rows and the two active long polls, the benchmark package has an
`adapter-drain` group with pre-fix numbers recorded in this plan, and BUG-1 is `confirmed`.

Start in `shibuya-pgmq-adapter/test/TmpPostgres.hs`. Export and add a variant of `withPgmqDb`
that hands the test the raw Hasql connection settings instead of a pre-built pool, so the test
can create pools of chosen sizes and names:

```haskell
-- | Like 'withPgmqDb', but hands the caller the connection settings so it can build
-- pools with specific sizes, timeouts, and application names.
withPgmqDbSettings :: (Settings.Settings -> IO a) -> IO (Either StartError a)
withPgmqDbSettings action = Pg.with $ \db -> do
  let connSettings = Pg.connectionSettings db
  installPgmqSchema connSettings
  action connSettings

-- | A pool of the given size and acquisition timeout whose connections announce an
-- application name, so a test can find them in pg_stat_activity.
createNamedPool :: Int -> DiffTime -> Text -> Settings.Settings -> IO Pool.Pool
createNamedPool size acquisition applicationName connSettings =
  Pool.acquire $
    PoolConfig.settings
      [ PoolConfig.size size,
        PoolConfig.acquisitionTimeout acquisition,
        PoolConfig.agingTimeout (secondsToDiffTime 3600),
        PoolConfig.idlenessTimeout (secondsToDiffTime 60),
        PoolConfig.staticConnectionSettings (connSettings <> Settings.applicationName applicationName)
      ]

-- | Create one extra uniquely named queue for the duration of an action.
withNamedQueue :: Pool.Pool -> Text -> (QueueName -> IO a) -> IO a
withNamedQueue pool prefix action = do
  suffix <- randomSuffix
  let name = case parseQueueName (prefix <> "_" <> suffix) of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
  runPgmqSession pool (Pgmq.createQueue name)
  action name `finally` runPgmqSession pool (void (Pgmq.dropQueue name))
```

`randomSuffix` already exists inside `withTestFixture`; lift it to a top-level function.
`DiffTime` comes from `Data.Time`, and `Settings.applicationName` from
`Hasql.Connection.Settings` (hasql 1.10 exports it; it sets `application_name`).

In `shibuya-pgmq-adapter/test/TestUtils.hs`, add three oracle helpers. `queueRowCount`
counts every row of the queue table regardless of visibility, which is what the bug report
measures (a leased-but-unacknowledged row still counts); `activeLongPolls` is the external
scenario's query parameterised by application name; `waitUntil` polls a predicate every ten
milliseconds:

```haskell
queueRowCount :: Pool.Pool -> QueueName -> IO Int64
queueRowCount pool queueName =
  runPgmqSession pool $
    Session.statement () $
      Statement.preparable
        ("select count(*) from pgmq.q_" <> queueNameToText queueName)
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

activeLongPolls :: Pool.Pool -> Text -> IO Int64
activeLongPolls pool applicationName =
  runPgmqSession pool $
    Session.statement applicationName $
      Statement.preparable
        "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and application_name = $1 and state = 'active' and query like '%pgmq.read_with_poll%'"
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

waitUntil :: IO Bool -> IO ()
waitUntil condition = do
  ready <- condition
  unless ready $ threadDelay 10_000 >> waitUntil condition
```

`Statement.preparable` takes its SQL as `Text` in hasql 1.10, so the queue name is
concatenated directly; `queueNameToText` is exported by `Pgmq.Types`, and `Statement`,
`Session`, `Encoders`, and `Decoders` are the `Hasql.*` modules of the same names.

Now write the regression in `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs`.
Add a `sharedPoolSpec :: Spec` and call it from `spec` next to the `Database restart`
block (it manages its own database because it needs custom pools). The test mirrors the
external scenario:

```haskell
consumerApplicationName :: Text.Text
consumerApplicationName = "shibuya-pgmq-adapter-test-consumer"

sharedPoolSpec :: Spec
sharedPoolSpec = describe "Shared pool" $ do
  it "long polls on a saturated pool do not starve acknowledgements" $ do
    skipDb <- lookupEnv "PGMQ_TEST_SKIP_DB"
    case skipDb of
      Just "1" -> pendingWith "Database tests skipped (PGMQ_TEST_SKIP_DB=1)"
      _ -> do
        result <- withPgmqDbSettings $ \connSettings -> do
          consumerPool <- createNamedPool 2 (secondsToDiffTime 10) consumerApplicationName connSettings
          oraclePool <- createNamedPool 2 (secondsToDiffTime 10) "shibuya-pgmq-adapter-test-oracle" connSettings
          (`Exception.finally` (Pool.release consumerPool >> Pool.release oraclePool)) $
            withTestFixture oraclePool $ \TestFixture {queueName = firstQueue, dlqName} ->
              withNamedQueue oraclePool "test_second" $ \secondQueue -> do
                firstCalls <- newIORef (0 :: Int)
                secondCalls <- newIORef (0 :: Int)
                ackFailures <- newIORef (0 :: Int)
                let env = (mkPgmqAdapterEnv consumerPool) {onAckFailure = \_ _ -> bump ackFailures}
                    longPoll = LongPolling {maxPollSeconds = 5, pollIntervalMs = 100}
                    firstConfig = (defaultConfig firstQueue) {polling = longPoll}
                    secondConfig =
                      (defaultConfig secondQueue)
                        { polling = longPoll,
                          deadLetterConfig = Just (directDeadLetter dlqName True)
                        }
                    settled = do
                      a <- queueRowCount oraclePool firstQueue
                      b <- queueRowCount oraclePool secondQueue
                      d <- queueRowCount oraclePool dlqName
                      pure (a == 0 && b == 0 && d == 1)
                evidence <- runAdapterIO consumerPool $ runTracingNoop $ do
                  firstAdapter <- requireAdapterWith env firstConfig
                  secondAdapter <- requireAdapterWith env secondConfig
                  started <-
                    runApp
                      defaultAppConfig
                      [ (ProcessorId "shared-pool-ack-ok", mkProcessor firstAdapter (countingHandler firstCalls)),
                        (ProcessorId "shared-pool-dead-letter", mkProcessor secondAdapter (deadLetterHandler secondCalls))
                      ]
                  case started of
                    Left err -> error ("Failed to start app: " <> show err)
                    Right appHandle -> do
                      outcome <- liftIO $ do
                        -- Before the fix both processors sit inside read_with_poll; after the
                        -- fix no adapter connection ever does, so wait for the processors to
                        -- be polling by either signal.
                        pollsReady <- timeout 8_000_000 (waitUntil (pollingStarted oraclePool))
                        case pollsReady of
                          Nothing -> pure (Left "processors never started polling")
                          Just () -> do
                            sendTestMessage oraclePool firstQueue (String "first")
                            sendTestMessage oraclePool secondQueue (String "second")
                            sentAt <- getMonotonicTime
                            completed <- timeout ackDeadlineMicros (waitUntil settled)
                            doneAt <- getMonotonicTime
                            rows <- (,,) <$> queueRowCount oraclePool firstQueue <*> queueRowCount oraclePool secondQueue <*> queueRowCount oraclePool dlqName
                            polls <- activeLongPolls oraclePool consumerApplicationName
                            pure (Right (completed, doneAt - sentAt, rows, polls))
                      _ <- stopAppGracefully defaultShutdownConfig {drainTimeout = 10} appHandle
                      pure outcome
                calls <- (,) <$> readIORef firstCalls <*> readIORef secondCalls
                failures <- readIORef ackFailures
                pure (evidence, calls, failures)
        case result of
          Left err -> expectationFailure ("Failed to start temp database: " <> show err)
          Right (Left reason, _, _) -> expectationFailure reason
          Right (Right (completed, seconds, rows, polls), calls, failures) -> do
            putStrLn $
              "SHARED-POOL-ACK-DIAG: completed=" <> show (completed == Just ())
                <> " seconds=" <> show seconds <> " rows=" <> show rows
                <> " activeLongPolls=" <> show polls <> " handlerCalls=" <> show calls
                <> " ackFailures=" <> show failures
            calls `shouldBe` (1, 1)
            failures `shouldBe` 0
            case completed of
              Just () -> seconds `shouldSatisfy` (< ackDeadlineSeconds)
              Nothing ->
                expectationFailure $
                  "acknowledgements did not complete within " <> show ackDeadlineSeconds
                    <> "s: source rows " <> show rows <> ", active long polls " <> show polls
                    <> ", ack failures " <> show failures

ackDeadlineMicros :: Int
ackDeadlineMicros = 15_000_000

ackDeadlineSeconds :: Double
ackDeadlineSeconds = 15

-- Two consumer backends exist once both ingesters have read at least once; before the
-- fix they are also active inside read_with_poll.
pollingStarted :: Pool.Pool -> IO Bool
pollingStarted oraclePool = (>= 2) <$> consumerBackends oraclePool consumerApplicationName

requireAdapterWith ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) =>
  PgmqAdapterEnv ->
  PgmqAdapterConfig ->
  Eff es (Adapter es Value)
requireAdapterWith env config =
  pgmqAdapter env config >>= either (\err -> error ("Invalid PGMQ adapter config: " <> show err)) pure
```

`consumerBackends pool applicationName` is a fourth `TestUtils` helper identical to
`activeLongPolls` without the `state` and `query` predicates (it counts backends with that
application name); it is what makes the readiness wait valid both before and after the fix.
Before the fix, also log `activeLongPolls` at readiness so the transcript shows the two
active server-side polls. `getMonotonicTime` is `GHC.Clock.getMonotonicTime`. The test
collects evidence first and stops the application before asserting, so a failed assertion
never leaves processors running against a pool that is about to be released. Keep `rows` as
a triple of `Int64`.

Run this test against the unmodified library. It must fail, and the failure message must show
`source rows (1,1,0), active long polls 2, ack failures 0`; the diagnostic line shows the
handler calls `(1,1)`. Copy that transcript into Surprises & Discoveries; it is the in-repo
proof of the reported behaviour and of the mechanism (both connections busy in
`read_with_poll` while both acknowledgements wait).

Next, add the end-to-end benchmark. Create
`shibuya-pgmq-adapter-bench/bench/Bench/AdapterDrain.hs`, register `Bench.AdapterDrain` in
the benchmark stanza's `other-modules` in
`shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal`, and add
`AdapterDrain.benchmarks pool config` to the list in
`shibuya-pgmq-adapter-bench/bench/Main.hs`. The stanza already depends on `shibuya-core`,
`shibuya-pgmq-adapter`, `effectful-core`, `async`, and `tasty-bench`; add `process` (for
backend CPU sampling) and any other package the compiler asks for. The module follows the
self-timed pattern of `Bench.Fifo`: it measures only the region of interest and prints its
own report line so `--stdev Infinity` gives one clean sample per entry.

```haskell
module Bench.AdapterDrain (benchmarks) where

benchmarks :: Pool.Pool -> BenchConfig -> Benchmark
benchmarks pool config =
  bgroup
    "adapter-drain"
    [ bgroup
        "busy"
        [ bench "standard-100ms/batch-10" $ nfIO $ runDrain pool config "std" (StandardPolling 0.1),
          bench "long-poll-5s-100ms/batch-10" $ nfIO $ runDrain pool config "lp5" (LongPolling 5 100),
          bench "long-poll-1s-100ms/batch-10" $ nfIO $ runDrain pool config "lp1" (LongPolling 1 100)
        ],
      bgroup
        "idle-cost"
        [ bench "8-procs/long-poll-5s-100ms/20s" $ nfIO $ runIdleCost pool config "lp100" 8 20 (LongPolling 5 100),
          bench "8-procs/long-poll-5s-1000ms/20s" $ nfIO $ runIdleCost pool config "lp1000" 8 20 (LongPolling 5 1000),
          bench "8-procs/standard-1s/20s" $ nfIO $ runIdleCost pool config "std1" 8 20 (StandardPolling 1)
        ]
    ]
```

`runDrain` seeds `config.messageCount` messages, starts one Serial processor with
`batchSize = 10` and `visibilityTimeout = 120` under `runApp`, times the region from app
start until a counting handler has seen every message (`getMonotonicTime`), stops the app
outside the timed region, drops the queue unless `BENCH_SKIP_CLEANUP` is set, prints
`ADAPTER-DRAIN: polling=... messages=... seconds=... throughput=... msg/s`, and returns the
seconds. `runIdleCost` creates `n` empty queues, starts `n` processors on the benchmark pool
with the given polling, waits until `n` backends carry the pool's application name (set one on
the bench pool for this purpose, or count backends whose `query` mentions `pgmq.read`), then
samples three things at the start and end of the window: the client's `System.CPUTime.getCPUTime`,
the sum of `pg_stat_database.xact_commit` for the benchmark database (each client-side read is
one transaction, so after the fix this is the read count; before the fix it counts polls), and
the CPU time of the consumer backends read from `ps -o cputime= -p <pid,...>` for the pids in
`pg_stat_activity` with that application name (parse `mm:ss.cc`; sum). It prints
`IDLE-COST: polling=... processors=8 seconds=20 reads=... clientCpuSeconds=... backendCpuSeconds=...`
and returns the backend CPU seconds. Both functions run the adapter through
`runEff . runErrorNoCallStack @PgmqRuntimeError . runTracingNoop . runPgmq pool` and
unwrap the `Either` with `error`.

Capture the baseline with the benchmark server running (`just process-up` in one terminal)
and `BENCH_MESSAGE_COUNT=10000`:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
BENCH_MESSAGE_COUNT=10000 cabal bench shibuya-pgmq-adapter-bench \
  --benchmark-options='-p "$0 ~ /adapter-drain/ || $0 ~ /read.poll/ || $0 ~ /ack/ || $0 ~ /throughput/" --stdev Infinity'
```

Record every `ADAPTER-DRAIN:` and `IDLE-COST:` line and the tasty-bench times in the
Concrete Steps section under "Baseline (before fix)". Run it twice to see the run-to-run
spread; the comparison in M3 is only meaningful against that spread. Before the fix, the
idle-cost entries show a few reads per processor over the window and near-zero CPU; that is
the number the after-fix run is compared with.

Finally, confirm BUG-1. In
`docs/bug-reports/long-polls-starve-acknowledgements-on-a-shared-pool.md` change
`status: reported` to `status: confirmed` (the body already carries the root cause and the
recommended remedy, added on 2026-09-30) and, if the in-repo transcript adds anything the
body lacks, one sentence pointing at the `ChaosSpec` regression. Leave BUG-4 at `reported`
until M3 gives it in-repo evidence. Then log and validate:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
okf log add docs/bug-reports BUG-1 --kind Modification \
  -m "BUG-1 is confirmed: the adapter's own ChaosSpec reproduces the stall against 0.16.1.0 source (rows 1/1/0 and two active read_with_poll backends at a fifteen-second deadline) and the client-side LongPolling remedy is being implemented in plan 8."
okf validate docs/bug-reports --strict --profile docs/bug-reports/profile.dhall --profile-enforce --log-enforce
```

The bundle's `index.md`, `log.md`, BUG-1, and the new BUG-4 file already carry uncommitted
edits from the other process described in Surprises & Discoveries; review them with
`git diff docs/bug-reports` and include them in this milestone's commit if they validate,
since the confirmation builds on them.

Commit the fixture helpers, the benchmark, and the bug-report changes (the regression test is
committed with the fix in M2 so that this commit's suite is green):

```text
test(pgmq): add shared-pool fixtures and adapter drain benchmark

Add sized and named pool constructors plus row-count, backend, and
active-long-poll oracles for pool-contention tests, and an end-to-end
adapter benchmark covering busy drains and idle cost under standard and
long polling. Confirm BUG-1 and record BUG-4 in the bug-report bundle.

ExecPlan: docs/plans/8-fix-long-poll-acknowledgement-starvation-on-a-shared-pool.md
Intention: intention_01m3t2qeecekvrdbj2rfy522px
```

Acceptance for M1: the new test fails with the expected message against the current source;
the benchmark runs and its baseline numbers are recorded in this plan; `okf validate` passes;
the full existing suite still passes (`just test`, with the new test present but expected
to fail, or temporarily filtered with `--test-options='--skip "Shared pool"'`).

### Milestone 2: poll on the client and release the connection between reads

Scope: the source change and its unit tests. At the end, the shared-pool regression passes in
well under a second of acknowledgement latency, all existing tests pass, and stub-interpreter
tests prove the loop's timing, deadline, and stop-flag behaviour.

Edit `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`. Replace `pgmqChunks` and
its `where` block with:

```haskell
-- | Stream of message batches from pgmq. Each element is one poll's result.
-- Equivalent to 'pgmqChunksUntil' with a wait that is never interrupted.
pgmqChunks ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) (Vector Pgmq.Message)
pgmqChunks = pgmqChunksUntil (pure False)

-- | Stream of message batches whose long-poll wait ends early once the given
-- check returns True. The adapter passes its shutdown flag so a stopping
-- processor does not wait out the remainder of maxPollSeconds.
--
-- Long polling is a client-side loop, not pgmq's read_with_poll. A server-side
-- wait pins one pooled connection per processor for the whole wait while the
-- ingester re-polls the instant it returns the connection, and hasql-pool has no
-- waiter queue, so acknowledgements, lease renewals, and dead-letter moves on a
-- saturated pool could wait until shutdown (BUG-1). A server-side wait also keeps
-- running after the client process dies and charges the next visible message a
-- read attempt (BUG-4). Reading once per interval performs the same single
-- pgmq.read statement the server loop ran per interval, holds a connection only
-- during the read, and can be interrupted. See ADR 0002.
pgmqChunksUntil ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
  IO Bool ->
  PgmqAdapterConfig ->
  Stream (Eff es) (Vector Pgmq.Message)
pgmqChunksUntil stopWaiting config = Stream.repeatM (retryingTransient config.pollRetry poll)
  where
    poll :: (Pgmq :> es, IOE :> es) => Eff es (Vector Pgmq.Message)
    poll = waitFor $ case config.fifoConfig of
      Nothing -> readMessage (mkReadMessage config)
      Just fifo -> case fifo.readStrategy of
        ThroughputOptimized -> readGrouped (mkReadGrouped config)
        RoundRobin -> readGroupedRoundRobin (mkReadGrouped config)
        HeadPerGroup -> readGroupedHead (mkReadGrouped config)

    waitFor :: (IOE :> es) => Eff es (Vector Pgmq.Message) -> Eff es (Vector Pgmq.Message)
    waitFor readOnce = case config.polling of
      StandardPolling interval -> do
        result <- readOnce
        when (Vector.null result) $
          liftIO $
            threadDelay (nominalToMicros interval)
        pure result
      LongPolling maxSec intervalMs -> do
        start <- liftIO getMonotonicTime
        let deadline = start + fromIntegral maxSec
            interval = fromIntegral intervalMs / 1_000 :: Double
            loop = do
              result <- readOnce
              if not (Vector.null result)
                then pure result
                else do
                  now <- liftIO getMonotonicTime
                  stop <- liftIO stopWaiting
                  if stop || now + interval > deadline
                    then pure result
                    else do
                      liftIO $ threadDelay (fromIntegral intervalMs * 1_000)
                      loop
        loop

    nominalToMicros :: NominalDiffTime -> Int
    nominalToMicros t = floor (nominalDiffTimeToSeconds t * 1_000_000)
```

Then delete `mkReadWithPoll` and `mkReadGroupedWithPoll` (and their export lines), remove
`readWithPoll`, `readGroupedWithPoll`, `readGroupedRoundRobinWithPoll`, and
`readGroupedHeadWithPoll` from the `Pgmq.Effectful.Effect` import, remove
`ReadWithPollMessage (..)` and `ReadGroupedWithPoll (..)` from the
`Pgmq.Hasql.Statements.Types` import, add `pgmqChunksUntil` to the export list, and import
`GHC.Clock (getMonotonicTime)`. Change `pgmqChunksPrefetch` to take the stop check first and
pass it through:

```haskell
pgmqChunksPrefetch ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
  IO Bool ->
  (StreamP.Config -> StreamP.Config) ->
  PgmqAdapterConfig ->
  Stream (Eff es) (Vector Pgmq.Message)
pgmqChunksPrefetch stopWaiting prefetchSettings config =
  pgmqChunksUntil stopWaiting config
    & StreamP.parBuffered prefetchSettings
    & Stream.morphInner (withUnliftStrategy (ConcUnlift Ephemeral Unlimited))
```

In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs`, import `pgmqChunksUntil` instead of
`pgmqChunks` and make `chunkStream` in `pgmqSourceWithShutdown` read:

```haskell
    chunkStream = case config.prefetchConfig of
      Nothing -> pgmqChunksUntil (readTVarIO shutdownVar) config
      Just prefetch ->
        pgmqChunksPrefetch
          (readTVarIO shutdownVar)
          (StreamP.maxBuffer (fromIntegral prefetch.bufferSize))
          config
```

The deadline check `now + interval > deadline` guarantees a poll returns within
`maxPollSeconds` plus one read; the first read always happens, so a message that is already
visible is returned immediately, exactly as `read_with_poll` did. `retryingTransient` still
wraps the whole poll, so a transient error inside the loop restarts the loop with a fresh
deadline; that only lengthens a poll under repeated transient failures and is bounded by the
retry budget. `keepChunk` in `pgmqSourceWithShutdown` still decides whether a chunk is kept
and still releases just-read messages on shutdown.

Update `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/InternalSpec.hs`. Delete
`mkReadWithPollSpec` and any `mkReadGroupedWithPoll` cases. In `fifoDispatchSpec`, the three
long-poll cases now expect `readGrouped`, `readGroupedRoundRobin`, and `readGroupedHead`
with `pollParameters = Nothing`; make `observeFifoPoll`'s interpreter `error` on any
`*WithPoll` constructor so a regression back to the server-side loop fails loudly, and drop
`recordLong`. `runStubPgmq` can keep matching the `*WithPoll` constructors (they still exist
in the effect) but should also `error` on them for the same reason. Then add
`clientLongPollSpec` and call it from `spec`:

```haskell
clientLongPollSpec :: Spec
clientLongPollSpec = describe "pgmqChunksUntil client-side long poll" $ do
  it "returns a non-empty first read immediately" $ do
    (elapsed, reads) <- observeLongPoll (pure False) (LongPolling 5 200) (const (Just testMessage))
    reads `shouldBe` 1
    elapsed `shouldSatisfy` (< 0.1)
  it "re-reads every pollIntervalMs and returns empty at maxPollSeconds" $ do
    (elapsed, reads) <- observeLongPoll (pure False) (LongPolling 1 200) (const Nothing)
    reads `shouldSatisfy` (\n -> n >= 3 && n <= 7)
    elapsed `shouldSatisfy` (\t -> t >= 0.7 && t <= 1.4)
  it "stops waiting when the stop check is set" $ do
    (elapsed, reads) <- observeLongPoll (pure True) (LongPolling 5 200) (const Nothing)
    reads `shouldBe` 1
    elapsed `shouldSatisfy` (< 0.1)
  it "returns the first non-empty read after empty ones" $ do
    (elapsed, reads) <- observeLongPoll (pure False) (LongPolling 5 200) (\n -> if n >= 3 then Just testMessage else Nothing)
    reads `shouldBe` 3
    elapsed `shouldSatisfy` (\t -> t >= 0.3 && t < 1.0)
```

`observeLongPoll stop polling respond` builds a config from `retryTestConfig 1` with the
given polling, runs `Stream.toList (Stream.take 1 (pgmqChunksUntil stop config))` under an
interpreter that counts `ReadMessage` calls in an `IORef`, answers `respond n` (a `Maybe
Message` turned into a vector), and errors on any other operation; it returns the wall time
(`getMonotonicTime` around the run) and the read count. Add one parameterised variant over
the three FIFO strategies asserting that the grouped standard operation is the one called
under `LongPolling`.

Run the shared-pool regression and then the full suite:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
cabal test shibuya-pgmq-adapter-test --enable-tests --test-options='-m "Shared pool"'
cabal test shibuya-pgmq-adapter-test --enable-tests
```

The regression's diagnostic line should show `completed=True`, `activeLongPolls=0`, and
`seconds=` well under one (both acknowledgements only wait for the next 100 ms sleep of a
poll, if that); record it in Surprises & Discoveries. Format with `nix fmt`, then commit:

```text
fix(pgmq): poll on the client for LongPolling instead of read_with_poll

A server-side long poll pinned one pooled connection per processor for
the whole wait while the ingester re-polled the instant it returned the
connection, and hasql-pool has no waiter queue, so acknowledgements,
lease renewals, and dead-letter moves on a saturated pool waited until
shutdown. It also kept running after a client process died and charged
the next visible message a read attempt.

LongPolling now reads once per pollIntervalMs on the client until
maxPollSeconds elapse, holds a connection only during each read, and
stops waiting on shutdown. PollingConfig is unchanged.

Adds a PostgreSQL regression with two long-polling processors on a
two-connection pool and stub-timed unit tests for the loop.

Fixes: mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-1
Fixes: mori://shinzui/shibuya-pgmq-adapter/okf/bug-reports/concepts/BUG-4

ExecPlan: docs/plans/8-fix-long-poll-acknowledgement-starvation-on-a-shared-pool.md
Intention: intention_01m3t2qeecekvrdbj2rfy522px
```

Acceptance for M2: the shared-pool regression passes; `clientLongPollSpec` and the updated
FIFO dispatch cases pass; the whole suite passes.

### Milestone 3: prove there is no performance regression

Scope: measurements and guards. At the end, this plan holds a before/after table for the
benchmark groups, the idle cost is quantified with a documented conclusion, and three
`ChaosSpec` guards protect the properties the loop must keep.

Add three tests to `sharedPoolSpec`. The first is BUG-4's adapter-level guard and the
regression against ever reintroducing the server-side loop:

```haskell
  it "a LongPolling processor never issues read_with_poll" $ do
    -- withPgmqDbSettings; oracle pool; named consumer pool of size 2
    -- one processor with LongPolling {maxPollSeconds = 2, pollIntervalMs = 100}
    -- sample activeLongPolls oraclePool consumerApplicationName every 50 ms for 3 s
    -- every sample must be 0; also assert consumerBackends >= 1 at least once
```

The second checks the idle read cadence, guarding against a busy loop or a lost sleep:

```haskell
  it "an idle long-polling processor reads once per pollIntervalMs" $ do
    -- consumer pool size 1 with an interpreter-side counter: wrap runPgmq with
    -- a small `interpret` shim that counts ReadMessage dispatches before forwarding
    -- (or count xact_commit for the ephemeral database from the oracle pool)
    -- LongPolling {maxPollSeconds = 1, pollIntervalMs = 100}, idle for 3.5 s
    -- expect between 20 and 50 reads
```

The third measures idle pickup latency, guarding the bound that the sleep must not exceed
the configured check interval:

```haskell
  it "a message sent during an idle long poll is handled within one check interval plus slack" $ do
    -- consumer pool size 2, LongPolling {maxPollSeconds = 5, pollIntervalMs = 100}
    -- wait until consumerBackends >= 1, then sendTestMessage and time the handler call
    -- assert the handler ran within 1.0 s
```

Re-run the benchmark command from M1 with the same `BENCH_MESSAGE_COUNT` and record the
results under "After fix" next to the baseline. Acceptance for the busy entries: each
`adapter-drain/busy` entry and each existing group measures within the baseline's
run-to-run spread; the long-poll drains are within that spread of the standard-polling
drain, because a queue with messages never sleeps. Acceptance for the idle entries: at
`LongPolling 5 100` with eight idle processors over twenty seconds, the client CPU delta and
the summed backend CPU delta each stay below 0.2 CPU-seconds (one percent of one core per
window), and `reads` is about 1,600; at `LongPolling 5 1000` both CPU deltas are roughly a
tenth of that and `reads` about 160; the `StandardPolling 1` reference is close to the
1000 ms long-poll entry. If the 100 ms entry misses the budget on this machine, record the
numbers and change the documented guidance in M4 to recommend a larger `pollIntervalMs` for
mostly idle queues; do not change the design. If any busy entry regresses beyond the spread,
stop, record it in Surprises & Discoveries, and investigate before continuing; the only
expected source of difference is the final wait before shutdown, which is outside the timed
region and is now shorter.

Give BUG-4 its in-repo evidence: with the first guard passing, edit
`docs/bug-reports/long-poll-outlives-a-killed-client-and-consumes-a-read-attempt.md` to
`status: confirmed`, note the guard in one sentence in its body, log it (`okf log add
docs/bug-reports BUG-4 --kind Modification -m ...`), and validate. Optionally, reproduce the
orphaned-loop symptom itself: from the test, run `psql` (available in the dev shell) through
`System.Process` against the ephemeral database with `-c "select msg_id from
pgmq.read_with_poll('<queue>', 30, 1, 10, 100)"` on a queue whose one message was sent with
a two-second delay, `terminateProcess` it after 300 ms, and observe through the oracle that
`pg_stat_activity` still shows the backend and that the row's `read_ct` becomes 1 about
three seconds after the send. This documents PGMQ's behaviour and is not required for
acceptance.

Commit:

```text
test(pgmq): guard client-side long polling cadence, pickup, and absence of read_with_poll

ExecPlan: docs/plans/8-fix-long-poll-acknowledgement-starvation-on-a-shared-pool.md
Intention: intention_01m3t2qeecekvrdbj2rfy522px
```

### Milestone 4: document the behaviour and record the decision

Scope: user-facing and internal documentation, capability evidence, the ADR, and changelog
entries. Nothing here changes behaviour.

In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs`, rewrite the `LongPolling`
haddock: the adapter reads once and, while nothing is available, sleeps `pollIntervalMs` and
reads again until `maxPollSeconds` have elapsed, then yields an empty poll; a pooled
connection is held only during each read; each read is one `pgmq.read` statement, so
`pollIntervalMs` sets the idle round-trip rate (100 ms is ten reads per second per idle
processor, 1000 ms is one); shutdown interrupts the wait within one interval. Remove the
sentence "Long polling blocks in PostgreSQL until messages are available or the wait
expires". State the relationship to `StandardPolling` honestly: both hold no connection
between reads; `LongPolling` differs in yielding one empty result per `maxPollSeconds`
instead of one per interval and in the bounded-wait meaning of `maxPollSeconds`.

In `docs/pgmq-adapter/CONFIGURATION.md`, rewrite the `LongPolling` "Behavior" list (four
steps: read; return if non-empty; otherwise sleep `pollIntervalMs` unless shutting down or
`maxPollSeconds` reached; repeat), replace the "Trade-offs" list (no connection held between
reads; shutdown within one interval; idle round trips once per `pollIntervalMs`, tunable),
and update the Tuning Guidelines table and add a "Pool sizing and idle cost" paragraph:
pool size must cover concurrent handler work and acknowledgements, not one connection per
long-polling processor; for mostly idle queues pick the largest `pollIntervalMs` whose pickup
latency is acceptable. Record the M3 idle-cost numbers there in one sentence. Update
`docs/pgmq-adapter/INTERNALS.md` (the `pgmqChunks` excerpt, `pgmqChunksUntil`, removal of
`mkReadWithPoll` and `mkReadGroupedWithPoll` from the query-constructor list and the
pgmq-effectful table, and the prefetch signature), `docs/pgmq-adapter/ARCHITECTURE.md` (the
"Long Polling" diagram and bullets), `docs/pgmq-adapter/README.md` (the polling row), and
`docs/user/pgmq-getting-started.md` (the "Long Polling" paragraph) to match.

In `docs/capabilities/consume-pgmq-queue.md`, replace "Standard or long polling" with a
sentence that both modes poll from the client and that long polling bounds one wait by
`maxPollSeconds`, add a Limits bullet on idle round trips and `pollIntervalMs`, and add an
evidence entry for the shared-pool regression and the no-server-side-poll guard in
`ChaosSpec`. Run `just check-capabilities` and fix whatever the profile demands (for
example a refreshed `generated.at` or a bundle log entry via `okf log add docs/capabilities
CAP-1 ...`).

Write `docs/adr/0002-poll-pgmq-client-side-for-long-polling.md` in the same shape as ADR
0001 (title, Status: Accepted, Date, Context, Decision, Consequences). Context summarises the
mechanism in this plan's Context section and BUG-4; Decision states that `LongPolling` is a
client-side loop of single reads that never issues `read_with_poll` or its grouped variants,
holds a connection only during a read, checks the shutdown flag between reads, and keeps
`PollingConfig` unchanged; it names the rejected pause-after-empty-poll alternative and why.
Consequences state the acknowledgement behaviour on a saturated pool, prompt shutdown, no
orphaned server-side loops, unchanged busy throughput, the idle round-trip cost with
`pollIntervalMs` as its knob and the measured numbers, and that `pgmq-effectful` keeps
exporting the `*WithPoll` operations for other consumers. Link the ADR from both bug
reports' bodies and from the code comment.

Add an `## Unreleased` section at the top of both `shibuya-pgmq-adapter/CHANGELOG.md` and the
root `CHANGELOG.md` with a "Bug Fixes" entry (long polling now runs on the client; the
mechanism in one sentence; BUG-1 and BUG-4; the shutdown improvement), a "Behaviour Changes"
entry (idle round trips once per `pollIntervalMs`; `pg_stat_activity` no longer shows
`read_with_poll` for adapter connections; `Internal` lost `mkReadWithPoll` and
`mkReadGroupedWithPoll`, which were never public), and a "Tests and Benchmarks" entry (the
shared-pool regression, the three guards, the adapter drain and idle-cost benchmark).

Commit:

```text
docs(pgmq): describe client-side long polling, pool sizing, and idle cost

ExecPlan: docs/plans/8-fix-long-poll-acknowledgement-starvation-on-a-shared-pool.md
Intention: intention_01m3t2qeecekvrdbj2rfy522px
```

### Milestone 5: release and close the reports

Scope: publish, close BUG-1 and BUG-4, and re-run the external scenario. The release itself
is run by the user through the repository's `/release` skill, which bumps the version, moves
the Unreleased entries, tags, and uploads; recommend `minor` so the version becomes 0.16.2.0
(see Decision Log). Before invoking it, make sure `cabal.project.local` carries no local
override of `shibuya-core` or `pgmq-*`, and delete any stale `*-inplace.conf` under
`dist-newstyle/packagedb` if `cabal build all` reports a `mkPackageIndex` assertion.

After the version is on Hackage, edit both bug reports: `status: fixed`, `fixedVersion:
"<released version>"`, and a `resolution` paragraph like BUG-2's, naming the client-side
loop, the in-repo regression or guard, and the measured idle cost. Log each with `--kind
Modification`, validate exactly as in M1, then commit:

```text
docs(pgmq): close BUG-1 and BUG-4 as fixed in <released version>

ExecPlan: docs/plans/8-fix-long-poll-acknowledgement-starvation-on-a-shared-pool.md
Intention: intention_01m3t2qeecekvrdbj2rfy522px
```

Then run the external probe from `/Users/shinzui/Keikaku/bokuno/keiro-runtime-kenshou` after
updating its `cohort/shibuya-current.project` pin to the released version (that repository's
own conventions apply; do not edit it as part of this plan's commits):

```bash
cabal --project-file=cohort/shibuya-current.project run kenshou-shibuya-test -- --pgmq-live-probe 18
```

Expected: the scenario reports no `acknowledgement-deadline` failure, `firstAckSeconds` and
`secondAckSeconds` well under one second, `beforeStopFirstRows` and `beforeStopSecondRows` of
zero, `beforeStopDeadLetterRows` of one, and `beforeStopActiveLongPolls` of zero. Note that
the scenario's readiness wait currently requires two active `read_with_poll` backends, which
the fixed adapter never produces; that wait times out after eight seconds and the scenario
then reports `two long polls were not active together`. Retiring the `knownDefect` entry and
changing that readiness signal (for example to counting backends with the consumer
application name) are that project's follow-up; record the outcome here either way.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter` inside the Nix dev shell.

Build everything once to make sure the tree is healthy before editing:

```bash
cabal build all
```

Run only the new regression (M1 expects failure, M2 expects success):

```bash
cabal test shibuya-pgmq-adapter-test --enable-tests --test-options='-m "Shared pool"'
```

Expected before the fix (abridged):

```text
Chaos Tests
  Shared pool
    long polls on a saturated pool do not starve acknowledgements [✘]
SHARED-POOL-ACK-DIAG: completed=False seconds=15.0... rows=(1,1,0) activeLongPolls=2 handlerCalls=(1,1) ackFailures=0
Failures:
  acknowledgements did not complete within 15.0s: source rows (1,1,0), active long polls 2, ack failures 0
```

Expected after the fix (abridged):

```text
Chaos Tests
  Shared pool
    long polls on a saturated pool do not starve acknowledgements [✔]
SHARED-POOL-ACK-DIAG: completed=True seconds=0.2... rows=(0,0,1) activeLongPolls=0 handlerCalls=(1,1) ackFailures=0
```

Run the unit tests for the loop and the dispatch:

```bash
cabal test shibuya-pgmq-adapter-test --enable-tests --test-options='-m "client-side long poll"'
cabal test shibuya-pgmq-adapter-test --enable-tests --test-options='-m "FIFO dispatch"'
```

Run the whole suite and formatting:

```bash
just test
nix fmt
```

Benchmarks (start the server first with `just process-up` in another terminal; the dev shell
exports `PG_CONNECTION_STRING`):

```bash
BENCH_MESSAGE_COUNT=10000 cabal bench shibuya-pgmq-adapter-bench \
  --benchmark-options='-p "$0 ~ /adapter-drain/ || $0 ~ /read.poll/ || $0 ~ /ack/ || $0 ~ /throughput/" --stdev Infinity'
```

Record results here as the work proceeds.

Baseline (before fix), run 1 and run 2:

```text
(to be filled in M1)
```

After fix, run 1 and run 2:

```text
(to be filled in M3)
```

Bug-report bundle validation (M1, M3, and M5):

```bash
okf validate docs/bug-reports --strict --profile docs/bug-reports/profile.dhall --profile-enforce --log-enforce
```

Capability bundle validation (M4):

```bash
just check-capabilities
```


## Validation and Acceptance

The plan is accepted when all of the following hold.

Behaviour: with two processors on `LongPolling 5 100` sharing a two-connection pool, one
message sent to each queue is acknowledged while the application runs: the `AckOk` row is
deleted and the `AckDeadLetter` row is moved to the dead-letter queue within fifteen seconds
(observed well under one), the `onAckFailure` hook is never called, each handler ran exactly
once, and no adapter connection is ever active inside `pgmq.read_with_poll`. The shared-pool
regression in `ChaosSpec` encodes this and fails on the unmodified source with the transcript
shown in Concrete Steps.

Mechanism: the stub-timed unit tests show that under `LongPolling` a non-empty first read
returns immediately with one read, an always-empty queue is re-read every `pollIntervalMs`
until `maxPollSeconds` (three to seven reads and 0.7 to 1.4 s for `LongPolling 1 200`), a set
stop flag ends the wait after one read, and the FIFO strategies dispatch their standard
grouped reads.

Performance: the `adapter-drain/busy` entries and the existing `read/poll`, `ack`, and
`throughput` groups measure within the baseline's run-to-run spread after the fix; the
`adapter-drain/idle-cost` entries meet the budget in M3 or the documentation reflects the
measured numbers; an idle `LongPolling 1 100` processor performs between 20 and 50 reads in
3.5 s; a message sent to an idle `LongPolling 5 100` processor is handled within one second.

Documentation and records: haddocks, the five adapter documents, the capability record, ADR
0002, both changelogs, and BUG-1 and BUG-4 (`confirmed` during the work, `fixed` with
`fixedVersion` and `resolution` in M5) are updated and validate under their profiles.

Mutation evidence: temporarily restore a `readWithPoll` call in the `LongPolling` branch and
confirm the shared-pool regression fails again with the original transcript and the
no-server-side-poll guard fails; temporarily drop the `threadDelay` from the loop and
confirm the idle read-cadence guard fails and the idle-cost entry's read count explodes;
temporarily ignore `stopWaiting` and confirm the stop-flag unit test fails. Restore the
correct code before committing.


## Idempotence and Recovery

Every step is repeatable. The ephemeral database is created and destroyed per test; the
benchmark creates `bench_drain_*` and `bench_idle_*` queues with random suffixes and drops
them unless `BENCH_SKIP_CLEANUP` is set, and the benchmark server is a disposable local
instance under `db/`; never point `PG_CONNECTION_STRING` at a production database. If a
benchmark run is interrupted, drop the leftover `bench_drain_*` and `bench_idle_*` queues or
reset the database with `just reset-database`.

If the regression test is flaky before the fix (it should not be; the stall is deterministic
on one capability and overwhelmingly likely across capabilities), run it three times and
record all outcomes. If it is flaky after the fix, first check that the consumer pool's
acquisition timeout is ten seconds and that no other process holds connections with the
consumer application name.

If `cabal build all` fails at configure with a `mkPackageIndex` assertion, delete the stale
upstream `*-inplace.conf` files under `dist-newstyle/packagedb/ghc-*/`, run
`ghc-pkg recache --package-db=<that directory>`, and rebuild.

The bug-report bundle already holds uncommitted edits from another process (see Surprises &
Discoveries). Do not discard them; validate and commit them with M1. If they fail validation,
fix the metadata rather than reverting the content.

The source change is confined to `pgmqChunks`, `pgmqChunksPrefetch`, two deleted query
constructors, and one call site in `Pgmq.hs`; reverting the M2 commit restores the previous
behaviour exactly. Hackage uploads and tags are immutable: if the release step reports that
the version exists, stop and inspect Hackage rather than retrying with an invented version.


## Interfaces and Dependencies

No public type or function signature changes. The behavioural contract of
`Shibuya.Adapter.Pgmq.Config.PollingConfig`'s `LongPolling` constructor changes as
documented in M4: the wait runs on the client, one read per `pollIntervalMs`, bounded by
`maxPollSeconds`, interruptible by shutdown.

Internal module `Shibuya.Adapter.Pgmq.Internal` (an `other-module`, no PVP surface):

```haskell
pgmqChunks :: (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) => PgmqAdapterConfig -> Stream (Eff es) (Vector Pgmq.Message)
pgmqChunksUntil :: (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) => IO Bool -> PgmqAdapterConfig -> Stream (Eff es) (Vector Pgmq.Message)
pgmqChunksPrefetch :: (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) => IO Bool -> (StreamP.Config -> StreamP.Config) -> PgmqAdapterConfig -> Stream (Eff es) (Vector Pgmq.Message)
```

Removed from that module: `mkReadWithPoll`, `mkReadGroupedWithPoll`.

New test helpers in `TmpPostgres` (test-only):

```haskell
withPgmqDbSettings :: (Hasql.Connection.Settings.Settings -> IO a) -> IO (Either EphemeralPg.StartError a)
createNamedPool :: Int -> Data.Time.DiffTime -> Data.Text.Text -> Hasql.Connection.Settings.Settings -> IO Hasql.Pool.Pool
withNamedQueue :: Hasql.Pool.Pool -> Data.Text.Text -> (Pgmq.Types.QueueName -> IO a) -> IO a
```

New test helpers in `TestUtils` (test-only):

```haskell
queueRowCount :: Hasql.Pool.Pool -> Pgmq.Types.QueueName -> IO Data.Int.Int64
activeLongPolls :: Hasql.Pool.Pool -> Data.Text.Text -> IO Data.Int.Int64
consumerBackends :: Hasql.Pool.Pool -> Data.Text.Text -> IO Data.Int.Int64
waitUntil :: IO Bool -> IO ()
```

New benchmark module `Bench.AdapterDrain` exporting
`benchmarks :: Hasql.Pool.Pool -> BenchConfig.BenchConfig -> Test.Tasty.Bench.Benchmark`.

Dependencies and versions, unchanged: `hasql-pool ^>=1.4` (behaviour documented above from
1.4.2), `hasql ^>=1.10` (`Hasql.Connection.Settings.applicationName`), `pgmq-effectful
^>=0.6` (`PgmqAcquisitionTimeout` is transient; `readWithPoll` and the grouped variants stay
exported but unused by the adapter), `shibuya-core ^>=0.10.0.0` (`finalizeWithRetry`,
bounded inbox), `streamly ^>=0.11` (`Stream.repeatM`), `base` (`GHC.Clock.getMonotonicTime`,
`System.CPUTime`), `ephemeral-pg` and `pgmq-migration ^>=0.6` for tests, `tasty-bench ^>=0.4`
and `process` for the benchmark. External services: a local PostgreSQL 17 (dev shell) for
tests and benchmarks; the external probe uses `mori://shinzui/keiro-runtime-kenshou`'s own
environment.


## Revision notes

- 2026-09-30, before implementation began: the plan's remedy changed from "keep
  `read_with_poll` and sleep `pollIntervalMs` after an empty poll" to "poll on the client and
  never issue `read_with_poll`". During plan creation another Claude Code process appended a
  root-cause and remedy section to BUG-1 and added BUG-4, showing that the same server-side
  loop also outlives a killed client and consumes read attempts, which a pause cannot fix.
  Purpose, Decision Log, Context, all milestones, Validation, Idempotence, and Interfaces were
  rewritten to match; the Progress checklist was regenerated.
