---
id: 3
slug: prototype-re-enabling-pgmq-prefetch-via-scoped-concunlift
title: "Prototype re-enabling PGMQ prefetch via scoped ConcUnlift"
kind: exec-plan
created_at: 2026-07-03T15:42:58Z
---

# Prototype re-enabling PGMQ prefetch via scoped ConcUnlift

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The PGMQ adapter used to offer an opt-in "concurrent prefetch" feature: while the handler
processed the current batch of messages, a background worker polled the next batch, cutting
latency. That feature was **removed** in adapter release 0.9.0.0 (commit `2998a3f`, directed
by the shibuya-core repository's EP-27) because enabling it reliably deadlocked the consumer
with `thread blocked indefinitely in an STM transaction`. At the time the deadlock was
attributed to an unfixable interaction "inside streamly" and prefetch was deleted rather than
repaired.

A later investigation (recorded in EP-27's Decision Log and reproduced in the Context section
below) established that the deadlock is **not** a streamly bug and does **not** require any
upstream change. The root cause is that `effectful`'s default unlifting strategy, `SeqUnlift`,
throws when its unlifting function is invoked from a thread other than the one that created it
— which is exactly what streamly's `parBuffered` does when it spawns producer worker threads.
The fix is local to the adapter: run the concurrent portion of the stream under
`effectful`'s `ConcUnlift` strategy, which clones the effect environment per worker thread so
the unlift is legal off-thread.

After this plan, a user who sets `prefetchConfig = Just defaultPrefetchConfig` on a
`PgmqAdapterConfig` gets working, non-deadlocking concurrent prefetch, and a user who leaves it
`Nothing` (the default) is **completely unaffected** — their stream still runs under the
default `SeqUnlift` strategy with zero added overhead. You can see it working by running the
new deadlock-reproduction integration test (`just test`, DB-backed): with the fix it drains a
queue to completion under prefetch; against the old un-scoped code it hangs and is killed by
the test timeout.

This is an **explicitly prototype-scoped** plan. Its job is to prove the `ConcUnlift`
hypothesis empirically and decide, on evidence, whether to promote prefetch back into the
public API or leave it removed with the reproduction and findings recorded. It does not
commit to shipping prefetch; it commits to answering the question with a runnable test.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-07-03: M0: Baseline green — `just build` up to date; `just test` = 148 examples, 0 failures. (Note: 148, not EP-27's 146 — the tree already carried an uncommitted `finalizeAutoDeadLetter` refactor + 2 tests that are not part of this plan.)
- [x] 2026-07-03: M1: Reintroduced `PrefetchConfig`/`defaultPrefetchConfig`/`prefetchConfig` in `Config.hs` (with a `validateConfig` rule rejecting `bufferSize == 0` via `InvalidPrefetchBufferSize`); added `pgmqChunksPrefetch` in `Internal.hs` = `pgmqChunks config & StreamP.parBuffered settings & Stream.morphInner (withUnliftStrategy (ConcUnlift Ephemeral Unlimited))`; `pgmqSourceWithShutdown` selects the chunk stream by `prefetchConfig`. Re-exported from `Shibuya.Adapter.Pgmq`. `just build` green.
- [x] 2026-07-03: M1: Non-prefetch path unchanged — with `prefetchConfig = Nothing` the chunk stream is exactly `pgmqChunks config` (no `morphInner`/`withUnliftStrategy`); full suite still 148 examples, 0 failures. Added `prefetchConfig = Nothing` only to the six all-fields config literals in `IntegrationSpec.hs`/`InternalSpec.hs` that spelled out every field.
- [x] 2026-07-03: M2: Added DB-backed deadlock-reproduction test `Chaos/Prefetch/drains the queue under concurrent prefetch without deadlocking` (`ChaosSpec.hs`): 50 messages, `prefetchConfig = Just defaultPrefetchConfig`, `batchSize = 5`, drained through `runApp` + `countingHandler` under a 30 s `timeout`, then asserts the source queue is empty. Passes with the fix (full suite 149 examples, 0 failures). **Teeth verified**: stripping the `morphInner (withUnliftStrategy ...)` line makes it fail in ~0.9 s with `ExceptionInLinkedThread … "have a look at UnliftStrategy (ConcUnlift)."` — the exact effectful `SeqUnlift` off-thread error. Wrapper restored; re-run green.
- [x] 2026-07-04: M2: **Found a shutdown-release regression.** Differential test `Chaos/Prefetch/does not hold more messages invisible on shutdown …` (`ChaosSpec.hs`, helper `measureShutdownRelease`) runs the identical shutdown scenario with prefetch OFF vs ON and compares `held = total − processed − visibleAfterShutdown`. Reproducible result: prefetch strands ≈`bufferSize × batchSize` extra messages invisible after shutdown (e.g. off held=3, on held=11 → 8 extra; = 4×2). Cause confirmed as predicted: `parBuffered` buffers chunks upstream of the EP-27 shutdown gate, and only the chunk the gate pulls next is released; the rest sit in the buffer until VT expiry. **At-least-once safe** (no loss — pgmq redelivers after VT) but weakens EP-27's prompt shutdown-release. Test marked `pendingWith` (suite stays green: 150 examples, 0 failures, 1 pending).
- [x] 2026-07-04: M2: **Verified no data loss.** `ChaosSpec` test "loses no messages under prefetch: stranded messages are all redelivered after the VT" blocks the handler (messages read-ahead, never acked), shuts down, waits one VT window, and asserts `processed + recoverable == total`. Measured `0 + 20 == 20`, stable across three runs — the shutdown strand only delays redelivery, never loses a message.
- [ ] M2 (remaining, optional): explicit `unliftStrategy` probe test (`SeqUnlift` off-path / `ConcUnlift` on-path). Lower priority — scoping already demonstrated.
- [x] 2026-07-04: M3 decision: **accept and document** the shutdown-strand caveat (Decision Log). Chose over engineering a buffer-drain fix because the strand is intrinsic to read-ahead, bounded (`≤ bufferSize*batchSize`), and verified loss-free. Caveat written into the `PrefetchConfig` Haddock, the `prefetchConfig` field Haddock, and `docs/pgmq-adapter/ARCHITECTURE.md` (Shutdown Handling + Design Decision 6, which was updated from "Removed Lookaheading" to "Concurrent Prefetch (opt-in)"). Haddock builds; suite green at 151 examples, 0 failures.
- [x] 2026-07-04: M3: differential shutdown test converted from `pendingWith` to a **passing bounded-strand regression guard** (`heldOn <= bufferSize*batchSize + inbox slack`) now that the caveat is accepted+documented — so an *unbounded* future leak fails, while the documented bounded strand passes. Title updated to describe the bound rather than a comparison.
- [ ] M3 (remaining): changelog entry + version bump + full prose-doc pass (README/user guides) belong to the promotion/release milestone (M4), still pending the user's commit-strategy decision on the entangled WIP.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-03: `morphInner` is exported from the **public** `Streamly.Data.Stream` (line 756 in
  streamly-core 0.12.0), not only from `Streamly.Internal.Data.Stream.Lift`. So M1 uses
  `Stream.morphInner` with no `Internal` import — supersede the Interfaces note that expected an
  internal dependency. `Effectful` likewise re-exports `UnliftStrategy(..)`, `Persistence(..)`,
  `Limit(..)`, and `withUnliftStrategy` (`Effectful.hs:42-46`), so no `Effectful.Internal` import
  is needed either.
- 2026-07-03: The working tree already carried unrelated uncommitted work when M1 began — a
  `finalizeAutoDeadLetter` extraction in `Internal.hs` (+ 2 `InternalSpec.hs` tests, hence the
  148 vs 146 baseline) and a large docs cleanup that *removes* the stale "lookahead" prefetch
  documentation. That doc cleanup is conceptually opposite to this plan (M3 re-adds prefetch
  docs). M1 code was kept additive and in a different region of `Internal.hs`, so it coexists;
  commit strategy for disentangling the two is deferred to the user. No commit was made in M1.
- 2026-07-03: fourmolu (0.19.0.1, project `fourmolu.yaml`) reordered the new `Numeric.Natural`
  import and reflowed the new `validateConfig` prefetch guard; the edited source files were
  formatted in place (`fourmolu --mode inplace`) and re-checked clean, without running a global
  `nix fmt` so the pre-existing WIP doc files were left untouched.
- 2026-07-04: **Shutdown-release regression under prefetch (confirmed, reproducible).** The
  scoped-`ConcUnlift` fix removes the deadlock, but prefetch introduces a distinct, separate
  correctness gap: on shutdown it strands ≈`bufferSize × batchSize` messages invisible in the
  queue that the non-prefetch path releases promptly. Differential measurement (`measureShutdownRelease`,
  `total=40, batchSize=2, bufferSize=4, vt=30`): `held` (= total − processed − visible-after-shutdown)
  was **3 with prefetch off vs 11 with prefetch on** across repeated runs — 8 extra = exactly one
  full `parBuffered` buffer (4 chunks × 2). Mechanism: `parBuffered` sits upstream of the EP-27
  shutdown gate (`takeWhileM keepChunk` → `releaseMessages`); when shutdown fires the gate pulls
  and releases only the next chunk, then ends the stream (`takeWhileM` returns `False`), so the
  remaining buffered chunks never reach `releaseMessages` and stay invisible until pgmq redelivers
  them after their VT. This is **at-least-once safe** (no message loss) but delays redelivery by up
  to `visibilityTimeout` and weakens the prompt-release guarantee EP-27 established. This is the
  concrete evidence behind "not confident to ship prefetch": the drain-happy-path test hid it; the
  differential shutdown test exposed it. Recorded as a `pendingWith` test rather than a hard
  failure so the tree stays green while the gap is visible. M3 must resolve it (drain the buffer on
  shutdown, or accept+document the caveat) before promotion.
- 2026-07-03: With current effectful/streamly the un-scoped failure is **fail-fast, not a silent
  hang**. Stripping the wrapper made the reproduction test fail in ~0.9 s with
  `ExceptionInLinkedThread (ThreadId N) "… have a look at UnliftStrategy (ConcUnlift)."` — the
  literal `SeqUnlift` off-thread `error` from `seqUnliftIO`, surfaced via streamly's linked-thread
  exception propagation rather than the historically-reported `thread blocked indefinitely in an
  STM transaction`. Both are the same root cause; the modern manifestation just raises instead of
  deadlocking. M3 docs should describe the removed-feature history accurately: the symptom users
  saw historically was the STM hang, but the underlying error is the off-thread unlift. The
  behavioral test (drain-within-timeout) catches either manifestation.


## Decision Log

Record every decision made while working on the plan.

- Decision: This plan lives in the PGMQ adapter repository's own `docs/plans/` series (as plan
  #3), not in the shibuya-core repository alongside the MasterPlan-4 children (EP-22…EP-28).
  Rationale: The work is 100% adapter-local (no core change), the adapter already maintains an
  independent numbered plan series (`1-migrate-to-shibuya-core-0.5-and-dlq-trace.md`,
  `2-upgrade-pgmq-hs-and-hs-opentelemetry.md`), and MasterPlan 4 explicitly scoped the prefetch
  *fix* out of its remediation initiative (it only removed the footgun). This is therefore new,
  self-contained follow-up work rather than a MasterPlan-4 child. It is cross-referenced from
  EP-27 and MasterPlan 4 in the core repository for discoverability. Commits carry a single
  `ExecPlan: docs/plans/3-prototype-re-enabling-pgmq-prefetch-via-scoped-concunlift.md` trailer.
  Date: 2026-07-03

- Decision: The prototype uses `ConcUnlift Ephemeral Unlimited` as the initial strategy, scoped
  to the concurrent stream via `Streamly.Internal.Data.Stream.Lift.morphInner`, applied only in
  the `prefetchConfig = Just …` branch.
  Rationale: `Ephemeral` clones a fresh environment per unlift call, which is the safest match
  for streamly spawning an unknown, dynamic number of producer workers; `Unlimited` imposes no
  cap. `morphInner (withUnliftStrategy s)` wraps every monadic step of the wrapped sub-stream,
  so the strategy is in scope at the moment `parBuffered` forks (see Context: the failure is a
  *run-time* fork, so a construction-time `withUnliftStrategy` around a lazy stream value would
  not take effect). `Persistent` (a reused worker-env pool) is recorded as a follow-up perf
  option to try only after `Ephemeral` is proven correct.
  Date: 2026-07-03

- Decision: Prefetch is re-added only at the **chunk-polling** stage (wrapping `pgmqChunks`),
  never around `mkIngested`/finalization or the shutdown-release gate.
  Rationale: The value of prefetch is overlapping DB polling with handler work; the ack/finalize
  path and the EP-27 chunk-granularity shutdown gate have their own correctness invariants
  (transactional DLQ, phase-tracked idempotency, best-effort `set_vt 0` release) that must not
  run on forked worker threads. Confining `parBuffered` to polling keeps those invariants on the
  single consumer thread.
  Date: 2026-07-03

- Decision: The shutdown-strand gap (M2 finding) is **accepted and documented** for now, not
  engineered away. Prefetch may leave up to `bufferSize * batchSize` already-read messages
  invisible in the queue at shutdown; they are redelivered after their visibility timeout. This
  is documented as a bounded, at-least-once-safe caveat in the `PrefetchConfig` Haddock and the
  adapter prose docs, rather than fixed by draining the `parBuffered` buffer.
  Rationale: (1) **No data loss — verified, not assumed.** The `ChaosSpec` test "loses no
  messages under prefetch …" blocks the handler so messages are read-ahead but never acked,
  shuts down, waits one VT window, and confirms `processed + recoverable == total` (measured
  `0 + 20 == 20`, stable across three runs). pgmq `read` sets a visibility timeout but never
  deletes; only `AckOk`/dead-letter/archive remove a row, and none of those run on the strand
  path, so every stranded message reappears after its VT. (2) The strand is **intrinsic to
  read-ahead**: prefetch exists to read messages before they are processed, so any un-drained
  buffer at shutdown necessarily holds messages with a ticking VT — a gate move only converts the
  strand into a larger core-inbox residual (unconfirmed, depends on `parBuffered`/`withChannel`
  teardown semantics) rather than eliminating it. (3) The effect is bounded (`≤ bufferSize *
  batchSize`) and only **delays** redelivery by up to `visibilityTimeout`; it is the same hazard
  EP-27's docs already flagged ("prefetched messages have their VT ticking"). A real
  buffer-draining fix (bracket/finalizer or upstream gate) remains possible future work if prompt
  shutdown-release under prefetch becomes a requirement.
  Date: 2026-07-04


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

**Repositories.** This plan document lives in the PGMQ adapter repository,
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter` (its git root). All code
changes happen there. The paths below are relative to that git root; note the library package
directory shares the repository's name, so library sources sit under
`shibuya-pgmq-adapter/src/…`. The sibling core framework repository is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`; two of its documents motivate this
plan and should be read for background but are not edited here except for the cross-reference
noted under "Related plans":

- `docs/masterplans/4-review-remediation-core-lifecycle-ordering-api-performance-and-adapter-fixes.md`
  (MasterPlan 4) — its Scope boundary excluded the streamly deadlock fix.
- `docs/plans/27-harden-pgmq-adapter-ack-paths-and-dead-lettering.md` (EP-27) — removed prefetch
  in 0.9.0.0 and, in its Decision Log and revision note, recorded the corrected `ConcUnlift`
  root-cause finding that this plan acts on.

### The bug: why prefetch deadlocked (with evidence)

streamly's concurrent combinators require the stream's base monad to be `MonadAsync`. In
streamly 0.12.0 (`streamly/src/Streamly/Internal/Control/Concurrent.hs`):

```haskell
type MonadAsync m = (MonadUnliftIO m, MonadThrow m)            -- with internal-use-unliftio
type MonadAsync m = (MonadIO m, MonadBaseControl IO m, MonadThrow m)  -- default
```

`parBuffered` (`streamly/src/Streamly/Internal/Data/Stream/Concurrent.hs`) spawns producer
worker threads and runs the source stream's steps on them, obtaining an `Eff es a -> IO a`
unlifting function from the base monad.

For `Eff es`, that unlift is governed by `effectful`'s `UnliftStrategy`. Both instances that
could satisfy `MonadAsync (Eff es)` read the strategy dynamically from the `IOE` context
(`effectful-core/src/Effectful/Internal/Monad.hs`):

```haskell
instance IOE :> es => MonadUnliftIO (Eff es) where
  withRunInIO k = unliftStrategy >>= (`withEffToIO` k)          -- line 433

instance IOE :> es => MonadBaseControl IO (Eff es) where
  liftBaseWith k = unliftStrategy >>= (`withEffToIO` k)          -- line 449
```

The strategy defaults to `SeqUnlift`, installed once by `runEff` (`consEnv (IOE SeqUnlift)`,
line 421). And `SeqUnlift`'s unlift function **throws** the moment it is called off its
creating thread (line 214):

```haskell
seqUnliftIO es k = do
  tid0 <- myThreadId
  k $ \m -> do
    tid <- myThreadId
    if tid `eqThreadId` tid0
      then unEff m es
      else error "If you want to use the unlifting function to run Eff computations
                  in multiple threads, have a look at UnliftStrategy (ConcUnlift)."
```

Chain of events: consumer runs the prefetch stream under default `SeqUnlift` → `parBuffered`
forks a producer worker → the worker calls the unlift on its own (different) thread → the unlift
`error`s → the producer never produces → the consumer blocks forever on the channel's STM read
→ `thread blocked indefinitely in an STM transaction`. This is a property of the ambient
`effectful` strategy, not of streamly; no streamly release changes it (streamly 0.12.0's only
deadlock-related changelog entry is an unrelated `parDemuxScan` worker-exception fix).

### The fix: scoped ConcUnlift

`effectful` offers `ConcUnlift`, whose unlift clones the environment per worker thread so the
unlift is legal off-thread (`concUnliftIO`, `Monad.hs:245-248`, dispatched at `raiseWith`
line 499). It is selected via `withUnliftStrategy`, which is **dynamically scoped**
(`Monad.hs:172-173`):

```haskell
withUnliftStrategy :: IOE :> es => UnliftStrategy -> Eff es a -> Eff es a
withUnliftStrategy unlift = localStaticRep $ \_ -> IOE unlift
```

Because it is a local override, wrapping only the prefetch sub-stream leaves every other code
path on the default `SeqUnlift`. The subtlety: the deadlocking fork happens when the stream is
**run**, not when the stream value is **constructed**. A `withUnliftStrategy s $ pure someStream`
would set the strategy only during construction and revert before the steps execute. The
correct primitive is `morphInner`
(`streamly/core/src/Streamly/Internal/Data/Stream/Lift.hs:47`):

```haskell
morphInner :: Monad n => (forall x. m x -> n x) -> Stream m a -> Stream n a
```

With `m = n = Eff es` and `f = withUnliftStrategy (ConcUnlift Ephemeral Unlimited)`,
`morphInner f` wraps *every monadic step* of the wrapped stream in the strategy override — so
the strategy is in force at the instant `parBuffered`'s step forks and calls the unlift.

### Why core's existing `ConcUnlift` does not already fix this

The shibuya-core runner already uses `ConcUnlift Persistent Unlimited` when it consumes an
adapter's `source` — `runIngesterAndProcessor` (`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`,
~line 256) does `withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> … runInIO
(runIngesterWithMetrics metricsHandle adapter.source inbox)`. It is tempting to conclude the
source already runs under `ConcUnlift` and prefetch would therefore be safe with no adapter
change. That is **not** how it works, and the prototype must not rely on it:

`withEffToIO strat` uses `strat` only to build *that one* unlifting function; it does not rewrite
the `UnliftStrategy` stored in the effect environment. `ConcUnlift`'s unlift clones the *original*
environment (`ephemeralConcUnlift`/`persistentConcUnlift` call `cloneEnv es0`,
`effectful-core/src/Effectful/Internal/Unlift.hs:159`/`:171`), and that clone still carries the
strategy that was ambient before — `SeqUnlift`, installed by `runEff`. So when the adapter's
`parBuffered` runs *inside* `adapter.source` and calls `unliftStrategy`/`withRunInIO`, it reads
`SeqUnlift`, not core's `ConcUnlift`. Core's `ConcUnlift Persistent` governs how core spawns the
ingester/processor *children* as asyncs; it does not propagate as the ambient strategy into
nested concurrency the adapter introduces. Consequently the deadlock still reproduces against
current core, and depending on core's runner internals would be fragile besides. The adapter must
scope its own `ConcUnlift` locally, which is exactly what M1 does. (M2 step 2 confirms the
deadlock still reproduces against current core by stripping the wrapper and observing the hang.)

### The removed code (restore points)

The removal commit is `2998a3f` ("feat(ack)!: harden pgmq finalization paths"). Its parent
`2998a3f^` still has the original prefetch surface, which is the reference implementation to
adapt. Retrieve any of it with `git show 2998a3f^:<path>`. Key pieces:

- `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs` (parent): the config type

  ```haskell
  data PrefetchConfig = PrefetchConfig
    { bufferSize :: !Natural }        -- number of batches to buffer ahead (default 4)
    deriving stock (Show, Eq, Generic)

  defaultPrefetchConfig :: PrefetchConfig
  defaultPrefetchConfig = PrefetchConfig {bufferSize = 4}
  ```

  and a `prefetchConfig :: !(Maybe PrefetchConfig)` field on `PgmqAdapterConfig`, defaulting to
  `Nothing`.

- `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` (parent): the streaming layer,
  which imported `Streamly.Data.Stream.Prelude qualified as StreamP` and defined
  `pgmqChunksPrefetch`, `pgmqMessagesPrefetch`, `pgmqSourceWithPrefetch`, the core of which was

  ```haskell
  pgmqChunksPrefetch prefetchConfig config =
    pgmqChunks config
      & StreamP.parBuffered prefetchConfig    -- <-- the deadlock site
  ```

  Here `prefetchConfig :: StreamP.Config -> StreamP.Config` was produced in `Pgmq.hs` from the
  `PrefetchConfig` record via `StreamP.maxBuffer (fromIntegral prefetch.bufferSize)`.

- `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs` (parent): source selection in `pgmqAdapter`

  ```haskell
  let messageSource = case config.prefetchConfig of
        Nothing       -> pgmqSource config
        Just prefetch -> let prefetchSettings = StreamP.maxBuffer (fromIntegral prefetch.bufferSize)
                          in pgmqSourceWithPrefetch prefetchSettings config
  ```

### The current (0.9.0.0) code you are editing

Since the removal, `pgmqAdapter` and the source pipeline changed shape (EP-27 M3 moved the
shutdown gate to chunk granularity). Current
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs`:

```haskell
pgmqAdapter env config =
  case validateConfig config of
    Left err -> pure (Left err)
    Right validConfig -> do
      shutdownVar <- liftIO $ newTVarIO False
      let messageSource = pgmqSourceWithShutdown env validConfig shutdownVar
      pure $ Right Adapter { adapterName = …, source = messageSource, shutdown = … }

pgmqSourceWithShutdown env config shutdownVar =
  pgmqChunks config
    & Stream.filter (not . Vector.null)
    & Stream.takeWhileM keepChunk               -- chunk-granularity shutdown gate (EP-27)
    & Stream.unfoldEach (Unfold.unfoldr Vector.uncons)
    & Stream.mapMaybeM (mkIngested env config)
  where
    keepChunk chunk = do
      isShutdown <- liftIO $ readTVarIO shutdownVar
      if isShutdown then releaseMessages env config chunk >> pure False else pure True
```

`pgmqChunks config :: Stream (Eff es) (Vector Pgmq.Message)` is the polling stage and is where
prefetch belongs (wrap it, keeping the shutdown gate, flatten, and `mkIngested` on the consumer
side). The imports already present are `Streamly.Data.Stream (Stream)`,
`Streamly.Data.Stream qualified as Stream`, `Streamly.Data.Unfold qualified as Unfold`,
`Effectful (Eff, IOE, (:>))`, `Effectful.Error.Static (Error)`.

### Terms

- *prefetch* — polling the next message batch on a background worker while the current batch is
  being handled, so DB latency overlaps processing.
- *`parBuffered`* — streamly's combinator that evaluates a stream on worker threads into a
  bounded buffer for a separate consumer.
- *`UnliftStrategy` / `SeqUnlift` / `ConcUnlift`* — `effectful`'s policy for turning an
  `Eff es a` into `IO a`. `SeqUnlift` is same-thread-only (errors off-thread); `ConcUnlift`
  clones the env per thread so off-thread unlifting is safe.
- *`morphInner`* — streamly primitive that maps a natural transformation over the base monad of
  every step of a stream; used here to place a `withUnliftStrategy` override in run-time scope.

### Related plans

Update the two core-repository documents to point here (done as part of this plan's landing; see
Concrete Steps): EP-27's revision note and MasterPlan 4's Surprises/Decision Log already record
the `ConcUnlift` finding — add a one-line pointer to
`shibuya-pgmq-adapter/docs/plans/3-prototype-re-enabling-pgmq-prefetch-via-scoped-concunlift.md`
so the follow-up is discoverable from the initiative.

### Build/test commands (from the adapter git root)

```bash
just build      # = cabal build all
just test       # = cabal test shibuya-pgmq-adapter-test  (ephemeral PostgreSQL, no external DB)
nix fmt         # required before every commit (treefmt pre-commit hook)
```

The test suite starts its own ephemeral PostgreSQL (`test/TmpPostgres.hs`); DB specs can be
skipped with `PGMQ_TEST_SKIP_DB=1` but this plan's acceptance requires them, so run unsandboxed.
`librdkafka` is not involved here, but if the workspace needs native linkage use
`nix develop -c cabal …`.


## Plan of Work

Four milestones. M0 establishes a green baseline. M1 reintroduces prefetch with the scoped
`ConcUnlift` fix, narrowly confined to the polling stage and gated on config. M2 proves the fix
empirically with a deadlock-reproduction test and guards the "non-prefetch unaffected"
invariant. M3 turns the evidence into a promote-or-discard decision plus docs/changelog. Every
milestone leaves the tree buildable and `just test` green (M2's new test is expected to *pass*
after the fix; it is written to fail only against a deliberately un-scoped variant).

### Milestone 0 — Baseline

Scope: confirm the starting tree is releasable so any later red is attributable to this work.
Run `just build` and `just test`; expect the 0.9.0.0 suite (146 examples, 0 failures per EP-27).
Record the exact count in Progress. No code change.

### Milestone 1 — Reintroduce prefetch behind scoped ConcUnlift

Scope: restore the opt-in prefetch surface, but confine `parBuffered` to `pgmqChunks` and wrap
that concurrent sub-stream in the scoped strategy override. At the end, `prefetchConfig = Just …`
produces a prefetching source and `prefetchConfig = Nothing` produces exactly today's source.

1. **Config.** In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs`, reinstate
   `PrefetchConfig { bufferSize :: !Natural }` (with `Show`/`Eq`/`Generic`),
   `defaultPrefetchConfig = PrefetchConfig {bufferSize = 4}`, and add
   `prefetchConfig :: !(Maybe PrefetchConfig)` back to `PgmqAdapterConfig`, defaulting to
   `Nothing` in `defaultConfig`. Re-export all three from `Shibuya.Adapter.Pgmq`. Extend
   `validateConfig` with a rule rejecting `bufferSize == 0` (a zero buffer is a
   configuration mistake) — add a `PgmqConfigError` constructor for it.

2. **Streaming layer.** In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`, add the
   import `Streamly.Data.Stream.Prelude qualified as StreamP` and
   `Streamly.Internal.Data.Stream.Lift (morphInner)`, plus `Effectful (withUnliftStrategy)` and
   `Effectful.Internal.Monad (UnliftStrategy(..), Persistence(..), MaxNumberOfThreads(..))` — use
   whatever public re-export path exposes `ConcUnlift`, `Ephemeral`, `Unlimited` (prefer
   `Effectful` / `Effectful.Dispatch.Static` public exports; fall back to
   `Effectful.Internal.Monad` only if necessary and note it in Surprises). Add a
   prefetch-aware chunk stream:

   ```haskell
   -- | Chunk polling with concurrent prefetch, made safe under effectful by running the
   -- concurrent portion with ConcUnlift so parBuffered's worker threads may unlift Eff.
   pgmqChunksPrefetch ::
     (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
     (StreamP.Config -> StreamP.Config) ->
     PgmqAdapterConfig ->
     Stream (Eff es) (Vector Pgmq.Message)
   pgmqChunksPrefetch prefetchSettings config =
     pgmqChunks config
       & StreamP.parBuffered prefetchSettings
       & morphInner (withUnliftStrategy (ConcUnlift Ephemeral Unlimited))
   ```

   The `& morphInner …` must be applied *after* `parBuffered`, so the override is in scope for
   `parBuffered`'s own forking step.

3. **Source assembly.** In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs`, make
   `pgmqSourceWithShutdown` choose the chunk stream by config, changing only the first stage:

   ```haskell
   pgmqSourceWithShutdown env config shutdownVar =
     chunkStream
       & Stream.filter (not . Vector.null)
       & Stream.takeWhileM keepChunk
       & Stream.unfoldEach (Unfold.unfoldr Vector.uncons)
       & Stream.mapMaybeM (mkIngested env config)
     where
       chunkStream = case config.prefetchConfig of
         Nothing       -> pgmqChunks config
         Just prefetch -> pgmqChunksPrefetch
                            (StreamP.maxBuffer (fromIntegral prefetch.bufferSize)) config
       keepChunk chunk = …   -- unchanged
   ```

   The shutdown gate, flatten, and `mkIngested` remain on the consumer thread and are untouched,
   so all EP-27 finalization/shutdown invariants hold. When `prefetchConfig = Nothing`,
   `chunkStream = pgmqChunks config` with no `morphInner`/`withUnliftStrategy` anywhere — the
   non-prefetch path is byte-for-byte the current behavior.

4. **Callers.** Re-add `prefetchConfig = Nothing` to any config literals that spell out all
   fields (tests, `shibuya-pgmq-example/app/Consumer.hs`). Do **not** re-add the old
   "prefetch disabled due to STM deadlock" NOTE comment.

Commands: `just build`; `just test` (unchanged suite still green). Acceptance: builds; existing
tests pass; `prefetchConfig = Nothing` produces an unchanged source (M2 guards this).

Commit: `feat(prefetch): reintroduce opt-in prefetch under scoped ConcUnlift`.

### Milestone 2 — Prove no deadlock; guard the non-prefetch invariant

Scope: an integration test that would hang without the fix and completes with it, plus a test
that the override does not leak to the default path.

1. **Deadlock-reproduction test** in `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/IntegrationSpec.hs`
   (DB-backed, using `withTestFixture`): send N messages (e.g. 200) to a queue; build the adapter
   with `prefetchConfig = Just (PrefetchConfig {bufferSize = 4})` and a small `batchSize`; run the
   `adapter.source` stream to completion through a trivial handler that returns `AckOk`, under an
   explicit wall-clock timeout (e.g. `System.Timeout.timeout (30 * 10^6)`). Assert the run
   *completes within the timeout* and the source queue drains to zero. This is the crux: against
   the un-scoped `pgmqChunks config & StreamP.parBuffered …` the run never completes (the timeout
   fires) and against the scoped version it drains.

2. **Prove the test has teeth.** Once green, temporarily delete the
   `& morphInner (withUnliftStrategy …)` line, re-run just this spec, and confirm it now times out
   (or dies with `thread blocked indefinitely in an STM transaction`). Restore the line. Record
   the before/after in Surprises & Discoveries with the observed error. (Do not commit the
   stripped variant.)

3. **Non-prefetch-unaffected test.** Add a test that, with `prefetchConfig = Nothing`, the
   ambient strategy observed inside a source step is still `SeqUnlift`. Practical form: run a
   source whose step calls `Effectful.unliftStrategy` (via a tiny instrumented handler or a
   direct `pgmqChunks`-level probe) and assert it returns `SeqUnlift`; with
   `prefetchConfig = Just …` assert the wrapped chunk stage observes `ConcUnlift …`. This nails
   the "does not force ConcUnlift globally" guarantee from the plan's purpose.

Commands: `just test` (all specs green, including the new integration test). Acceptance as
described; the reproduction test demonstrably fails when the wrapper is stripped.

Commit: `test(prefetch): DB-backed deadlock reproduction and strategy-scoping guards`.

### Milestone 3 — Decide, document, record

Scope: convert evidence to a decision and make the docs honest either way.

If M2 is green and stable (run the integration test several times to rule out flakiness, and try
`bufferSize` 2/4/8), **promote**: update `docs/pgmq-adapter/README.md`, `ARCHITECTURE.md`,
`docs/user/pgmq-advanced.md`, and the `pgmqAdapter`/`defaultConfig` Haddocks to document prefetch
as supported again, explicitly stating (a) it runs the polling stage under `ConcUnlift`, (b)
prefetched messages have their visibility timeout ticking (`bufferSize * batchSize *
avgProcessingTime < visibilityTimeout`), and (c) the non-prefetch path is unchanged. Add a
`CHANGELOG.md` entry and bump the adapter version (minor: additive opt-in feature returning). Note
the version in this plan and in MasterPlan 4's Integration Points.

If M2 is *not* stable, **discard**: revert the M1 code, keep the reproduction test as a skipped
`xit`/documented case, and record the failure mode and measurements in Surprises & Discoveries.
The milestone is then complete as "discarded with evidence".

Either way, add the cross-reference pointer to this plan in the core repository's EP-27 and
MasterPlan 4 (see Concrete Steps).

Commit (promote): `feat(prefetch)!?: document and ship ConcUnlift-based prefetch` + `docs: …` +
`chore(release): …`. Commit (discard): `docs: record prefetch ConcUnlift prototype outcome`.


## Concrete Steps

All commands run from the adapter git root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter` unless stated. Plan-document
edits to this file are committed here with `docs(plans): …`. The two core-repository pointer
edits are committed in `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` with
`docs(plans): …`.

1. Baseline:

   ```bash
   cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
   just build
   just test        # expect: "146 examples, 0 failures", "PASS"
   ```

2. Recover the reference implementation to adapt (read-only):

   ```bash
   git show 2998a3f^:shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs | sed -n '455,515p'
   git show 2998a3f^:shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs   | sed -n '150,205p'
   ```

3. Implement M1 (edit the three files named in Plan of Work), then:

   ```bash
   just build
   just test
   nix fmt
   git add shibuya-pgmq-adapter/src shibuya-pgmq-example
   git commit    # feat(prefetch): reintroduce opt-in prefetch under scoped ConcUnlift
                 # body + trailer: ExecPlan: docs/plans/3-prototype-re-enabling-pgmq-prefetch-via-scoped-concunlift.md
   ```

4. Implement M2 tests, verify teeth by stripping/restoring the `morphInner` line, then:

   ```bash
   just test
   nix fmt
   git add shibuya-pgmq-adapter/test
   git commit    # test(prefetch): DB-backed deadlock reproduction and strategy-scoping guards
   ```

5. M3 decision + docs + changelog + the core-repo pointer edits, each committed with trailers.


## Validation and Acceptance

- **Primary (behavioral):** with `prefetchConfig = Just (PrefetchConfig {bufferSize = 4})`, the
  integration test drains a 200-message queue to zero within a 30-second timeout through an
  `AckOk` handler. Observing completion (not a timeout, not
  `thread blocked indefinitely in an STM transaction`) is the acceptance signal that the deadlock
  is gone. Removing the `morphInner (withUnliftStrategy …)` wrapper makes the same test time out —
  demonstrating the fix is load-bearing, not incidental.
- **Scoping guarantee:** with `prefetchConfig = Nothing`, `unliftStrategy` observed inside a
  source step is `SeqUnlift`; with prefetch enabled, the wrapped chunk stage observes
  `ConcUnlift`. This proves non-prefetch users are unaffected.
- **Regression:** the full `just test` suite stays green (baseline count from M0, plus the new
  specs), confirming EP-27's finalization/shutdown/validation behavior is intact.
- **Stability:** the integration test passes across repeated runs and `bufferSize ∈ {2,4,8}`.


## Idempotence and Recovery

All steps are re-runnable. `just build`/`just test` are idempotent. The M1 edits are additive and
config-gated: if the prototype is abandoned, revert the three source edits and the test file and
the tree returns to 0.9.0.0 behavior — non-prefetch users were never on the changed path. The
reference implementation is always recoverable from `git show 2998a3f^:…`, so nothing is lost by
experimenting. Avoid parallel `cabal` invocations against the same `dist-newstyle` after any
version bump (EP-27 observed build-plan corruption); run `cabal clean` then a serial
build/test if the plan changes.


## Interfaces and Dependencies

- `effectful` (already a dependency): `withUnliftStrategy :: IOE :> es => UnliftStrategy -> Eff es a -> Eff es a`,
  and the `UnliftStrategy` constructor `ConcUnlift Persistence MaxNumberOfThreads` with
  `Ephemeral`/`Persistent` and `Unlimited`/`Limited`. Confirm the public export path for these
  constructors at M1 (they exist in `Effectful.Internal.Monad`; check whether `Effectful` or
  `Effectful.Dispatch.Static` re-exports them and prefer the most public one).
- `streamly` (already a transitive dependency; make it a direct `build-depends` on the library if
  not already): `Streamly.Data.Stream.Prelude.parBuffered`,
  `Streamly.Data.Stream.Prelude.maxBuffer`, and
  `Streamly.Internal.Data.Stream.Lift.morphInner :: Monad n => (forall x. m x -> n x) -> Stream m a -> Stream n a`.
  `morphInner` currently lives in an `Internal` module; depending on it is acceptable for this
  adapter (note it in Interfaces if the public surface later exposes an equivalent).
- No `shibuya-core` change and no new top-level dependency are required.
- At the end of M1: `pgmqChunksPrefetch` exists with the signature above; `PrefetchConfig`,
  `defaultPrefetchConfig`, and `PgmqAdapterConfig.prefetchConfig` are restored and exported;
  `validateConfig` rejects `bufferSize == 0`.
- At the end of M2: a DB-backed integration test named for the deadlock reproduction exists and
  passes only with the scoped wrapper present.
