---
id: 7
slug: add-grouped-head-fifo-polling-to-the-pgmq-adapter
title: "Add grouped-head FIFO polling to the PGMQ adapter"
kind: exec-plan
created_at: 2026-09-16T12:48:28Z
intention: "intention_01m2b1p3vhe179jtr5qz6ghqks"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-16T12:48:28Z
---

# Add grouped-head FIFO polling to the PGMQ adapter

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Consumers currently choose between two FIFO reads that can lease several messages from the
same group in one poll. That is useful only when the consumer can guarantee that every leased
predecessor settles before a successor runs. After this work, callers can select
`HeadPerGroup`, which delegates to PGMQ 1.12's grouped-head operation and returns at most one
absolute head from each group in a batch. An invisible or delayed head blocks only its own
group.

The behavior is visible in unit dispatch tests, real-PostgreSQL integration tests, and a
safe-drain benchmark that deletes every leased message. A released adapter version will make
the strategy consumable by
`mori://shinzui/keiro/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption`
without a local source override.


## Progress

- [x] 2026-09-16: Verified through Mori, Hackage, upstream tags, and local source that
  `pgmq-effectful-0.6.0.0` exports `readGroupedHead` and `readGroupedHeadWithPoll`, while the
  latest adapter release is 0.15.0.0 and exposes only `ThroughputOptimized` and `RoundRobin`.
- [x] 2026-09-16: Added `HeadPerGroup` dispatch for standard and long polling. The focused
  tests cover all six strategy/polling combinations; the complete adapter suite passed with
  169 examples and 0 failures under the repository's Nix development shell.
- [x] 2026-09-16: Added adapter-path database integration coverage for one-head-per-group,
  invisible-head blocking, settled-head advance, and delayed-head independence. The two focused
  examples pass against ephemeral PostgreSQL.
- [x] 2026-09-16: Added and compiled the safe-drain matrix with independent drain-only timing,
  read-count assertions, median, p95, throughput, and an enforced 20 percent ratio gate. A
  one-sample 10,000-message/100-group smoke run passed and reduced reads from 10,000 to 1,000
  at batch 10 and 200 at batch 50.
- [x] 2026-09-16: Collected the three-sample 10,000-message release fixtures. Every grouped-head
  case passed the 20 percent gate. Across 100 groups, batch ten reduced reads from 10,000 to
  1,000 and batch fifty reduced them to 200.
- [x] 2026-09-16: Completed three high-cardinality samples by combining the retained first
  release-candidate sample with two additional isolated samples. Batch ten and fifty reduced
  reads from 100,000 to 10,000 and 2,000 and passed at ratios 0.115 and 0.036.
- [x] 2026-09-16: Updated public documentation, configuration guidance, capability evidence,
  changelogs, and the 0.16.0.0 package metadata. Formatting, all 169 tests, all-component builds,
  `cabal check`, the source distribution, strict capability validation, and `nix flake check`
  pass.
- [x] 2026-09-16: Published 0.16.0.0 source and Haddocks to Hackage, pushed annotated tag
  `v0.16.0.0` (peeling to release commit `7472c776`), and created a non-draft, non-prerelease
  GitHub release. Hackage reports 0.16.0.0 as normal.


## Surprises & Discoveries

- The released pgmq-hs 0.6 API uses the existing `ReadGrouped` and `ReadGroupedWithPoll`
  records for grouped-head reads, so the adapter needs no new query type or dependency-family
  bump.
- The existing FIFO benchmark times one read and deletes only that batch. The performance gate
  needs a loop that drains the whole seeded queue; otherwise it cannot compare database
  statement count or end-to-end throughput against the safe quantity-one baseline.
- The ambient compiler provides `base-4.20`, while this package requires `base-4.21`; direct
  `cabal test` cannot solve the package. `nix develop -c cabal test --enable-tests ...` selects
  GHC 9.12.4 and is the reproducible validation command.
- Mutation evidence confirms the integration test exercises adapter dispatch: routing
  `HeadPerGroup` through `readGrouped` changed the first batch from expected IDs `[1,3]` to
  `[1,2,3,4]` and failed the one-head-per-group assertion. Restoring `readGroupedHead` makes
  both focused examples pass.
- The 10,000-message/100-group benchmark smoke run measured the safe legacy quantity-one drain
  at 96.212 seconds and grouped heads at 14.483 seconds (batch one), 1.636 seconds (batch ten),
  and 0.605 seconds (batch fifty). Read counts were 10,000, 10,000, 1,000, and 200 respectively;
  every grouped-head ratio passed the 20 percent gate. These are smoke values, not the final
  three-sample release evidence.
- Mutation evidence also covers the performance guard: forcing every grouped-head query to
  quantity one made the batch-ten case report 10,000 reads instead of the expected 1,000, and
  the benchmark failed with `unexpected safe FIFO read count`. The requested batch dispatch
  was restored before the release matrix.
- A full legacy quantity-one drain is not a viable baseline for the 100,000-message/10,000-group
  fixture. After about 20 minutes it had completed only 123 of 100,000 reads; three samples
  would take days. The run was stopped without retaining a timing result. The release matrix
  keeps legacy quantity one for both 10,000-message fixtures and uses grouped-head quantity one
  as the safe baseline for the high-cardinality fixture.
- On the Apple M1 Max/64 GB release host with PostgreSQL 17.10, the three-sample 10,000-message
  one-group fixture measured legacy quantity one at median 29.953141 s, p95 32.980475 s, and
  333.85 messages/s. Grouped heads measured 14.794956 s/14.900047 s/675.91 messages/s at
  quantity one (ratio 0.494), 14.160436 s/15.041024 s/706.19 messages/s at quantity ten
  (ratio 0.473), and 21.275268 s/22.499027 s/470.03 messages/s at quantity fifty (ratio 0.710).
  Every case necessarily used 10,000 reads because one group exposes only one absolute head.
- On the same host, the three-sample 10,000-message/100-group fixture measured legacy quantity
  one at median 77.516639 s, p95 99.496990 s, and 129.00 messages/s over 10,000 reads. Grouped
  heads measured 13.305524 s/13.652526 s/751.57 messages/s over 10,000 reads at quantity one
  (ratio 0.172), 1.595694 s/1.622075 s/6,266.87 messages/s over 1,000 reads at quantity ten
  (ratio 0.021), and 0.562668 s/0.583603 s/17,772.47 messages/s over 200 reads at quantity fifty
  (ratio 0.007). All ratios passed the gate.
- The three-sample 100,000-message/10,000-group fixture used grouped-head quantity one as its
  safe baseline. Its sample times were 1,128.905983 s, 974.735206 s, and 1,044.325426 s: median
  1,044.325426 s, p95 1,128.905983 s, 95.76 messages/s, and 100,000 reads. Quantity ten used
  10,000 reads with samples 127.456734 s, 115.160096 s, and 120.252500 s: median 120.252500 s,
  p95 127.456734 s, 831.58 messages/s, ratio 0.115. Quantity fifty used 2,000 reads with samples
  42.513543 s, 35.181133 s, and 37.467157 s: median 37.467157 s, p95 42.513543 s, 2,669.00
  messages/s, ratio 0.036. Both batched cases passed the gate.


## Decision Log

- Decision: Add `HeadPerGroup` as a third exported `FifoReadStrategy` constructor.
  Rationale: Grouped heads have different selection and performance semantics from both legacy
  reads. Reusing an old constructor would silently change behavior, while an explicit
  constructor lets downstream jobs state the PGMQ 1.12 requirement.
  Date: 2026-09-16

- Decision: Treat the exported-constructor addition as a PVP-breaking release.
  Rationale: Downstream exhaustive pattern matches stop compiling when a public sum type gains
  a constructor. The adapter is currently 0.15.0.0, so the release version will be 0.16.0.0
  unless authoritative release state changes before publication.
  Date: 2026-09-16

- Decision: Benchmark complete safe drains and keep wall-clock measurements out of ordinary CI.
  Rationale: Integration tests should prove selection semantics deterministically. A local
  release benchmark can measure realistic query cost without making CI timing-sensitive.
  Date: 2026-09-16

- Decision: Use grouped-head quantity one, rather than legacy grouped quantity one, as the
  100,000-message/10,000-group baseline.
  Rationale: Both modes provide one-message safe consumption, but the legacy query performed
  only 123 reads in about 20 minutes on that fixture. Retaining it would turn a release check
  into a multi-day job. The smaller fixtures still measure the migration from the legacy safe
  baseline, while the large fixture measures the batching gain at realistic group cardinality.
  Date: 2026-09-16


## Outcomes & Retrospective

M1 and M2 are complete. `HeadPerGroup` is public and dispatches through the released pgmq-hs
grouped-head effects without changing retry, prefetch, finalization, or telemetry logic. Real
PostgreSQL coverage proves absolute-head blocking and independent groups, and its mutation check
fails on the unsafe legacy dispatch. The complete three-fixture performance matrix passes.
Multi-group batches reduce statements by 10x at quantity ten and 50x at quantity fifty, including
the 100,000-message fixture. Version 0.16.0.0 is published on Hackage with Haddocks and under the
annotated `v0.16.0.0` tag plus a non-draft GitHub release. All milestones are complete; downstream
Keiro can now validate against the registry release without a local path.


## Context and Orientation

PGMQ is a PostgreSQL-backed queue. A read leases rows by moving their visibility timestamp;
deleting or archiving a row settles it. FIFO messages identify their group in the
`x-pgmq-group` header. An absolute head is the smallest message ID in a group whether or not
it is currently visible. `read_grouped_head(queue, vt, qty)` leases only visible absolute
heads, so an invisible head blocks its successor while unrelated groups can advance.

`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs` exports `FifoReadStrategy`.
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` implements `pgmqChunks`: standard
polling dispatches `ThroughputOptimized` to `readGrouped` and `RoundRobin` to
`readGroupedRoundRobin`; long polling uses their `WithPoll` equivalents. Both grouped-head
functions already exist in released `pgmq-effectful-0.6.0.0`, found through
`mori://shinzui/pgmq-hs/packages/pgmq-effectful`.

`shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/InternalSpec.hs` interprets the dynamic PGMQ
effect for focused dispatch tests. `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/IntegrationSpec.hs`
uses `TmpPostgres.withPgmqDb` and pgmq migrations against an ephemeral database.
`shibuya-pgmq-adapter-bench/bench/Bench/Fifo.hs` seeds FIFO queues and currently measures
single grouped reads; it must gain complete drain cases.

The public contract appears in `docs/user/pgmq-advanced.md`,
`docs/capabilities/fifo-ordered-processing.md`, root `CHANGELOG.md`, and
`shibuya-pgmq-adapter/CHANGELOG.md`. The capability bundle is profile-governed and its log is
`docs/capabilities/log.md`; run its existing strict validation after editing it. This
repository has no `docs/adr/` corpus, so there is no local ADR to update. The durable Keiro
consumer contract remains owned by the cross-repository plan cited above.


## Plan of Work

### Milestone 1 — public strategy and exact dispatch

Extend `FifoReadStrategy` in `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs` with
`HeadPerGroup`, documenting that quantity bounds groups rather than members of one group and
that PGMQ 1.12 or later is required. In `Internal.hs`, import `readGroupedHead` and
`readGroupedHeadWithPoll`; select them for the new constructor in standard and long-poll
branches. Keep both legacy cases unchanged.

Extend the internal effect interpreter tests so every combination of three strategies and two
polling modes records the exact PGMQ operation and query arguments. M1 is accepted when the
focused unit suite proves six dispatch cases and the adapter library builds.

### Milestone 2 — real database semantics

Add FIFO helpers and integration examples in `IntegrationSpec.hs`. Seed two messages each in
groups `a` and `b`, using `SendMessageWithHeaders`, and create the conventional FIFO index.
Prove that a quantity larger than the group count returns only the two first IDs; a second read
returns no successors while those heads are invisible; deleting group `a`'s head makes only
`a2` eligible. Add a delayed-head example proving group `b` can advance while group `a` stays
blocked. Compare IDs and per-group subsequences, never cross-group result order. M2 is accepted
when the database tests pass against the ephemeral PGMQ 1.12-compatible schema.

### Milestone 3 — safe-drain performance evidence

Replace or extend `Bench.Fifo` with a `safe-fifo-drain` benchmark group. A safe drain repeatedly
reads and batch-deletes until the known fixture count is gone, returning the number of read
statements as evidence. Compare legacy grouped quantity one with grouped-head quantities 1,
10, and 50 for 10,000 messages in one group and 10,000 across 100 groups. For the
100,000-message/10,000-group fixture, compare grouped-head quantities 10 and 50 with
grouped-head quantity one; the discovery log explains why the legacy full drain is intractable
there. Use only the conventional FIFO GIN index. Record machine, PostgreSQL version,
fixture, batch, read count, median, p95, throughput, and whether each grouped-head case is no
more than 20 percent slower than its safe quantity-one baseline. If the gate fails, retain
`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` evidence and do not recommend the strategy until the
cause is resolved.

### Milestone 4 — public contract and release

Update the advanced guide, capability record and log, README/configuration references where
they enumerate strategies, and both changelogs. Explain that `HeadPerGroup` safely batches
independent group heads, that legacy reads can return several members of one group, that
handlers remain governed by the consuming framework, and that the mode requires PGMQ 1.12+.
Run formatting, build, tests, benchmark compilation, strict capability validation, and flake
checks. Bump the adapter from 0.15.0.0 to 0.16.0.0 for the breaking constructor addition,
unless Hackage/tag verification at release time shows a newer base. Build and inspect the
sdist, commit with this plan and intention trailers, tag, push, publish package and Haddocks to
Hackage, and create the GitHub release. M4 is accepted when Hackage and the upstream tag agree
and downstream Keiro can select the released version without a local package path.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`:

```bash
nix develop -c cabal test --enable-tests shibuya-pgmq-adapter-test --test-show-details=direct
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix fmt
git add docs/plans/7-add-grouped-head-fifo-polling-to-the-pgmq-adapter.md
nix flake check
```

Run the performance matrix only against the disposable local database:

```bash
just process-up
export PGHOST="$PWD/db"
export PGDATABASE=shibuya_pgmq_adapter
export PG_CONNECTION_STRING="postgresql:///shibuya_pgmq_adapter?host=$(jq -rn --arg x "$PGHOST" '$x|@uri')"
BENCH_SAFE_FIFO_RUNS=3 nix develop -c cabal bench shibuya-pgmq-adapter-bench \
  --benchmark-options='-p safe-fifo-drain --stdev Infinity'
```

Before release, verify authority again and validate the package artifact:

```bash
curl -fsSL https://hackage.haskell.org/package/shibuya-pgmq-adapter.json
git ls-remote --tags https://github.com/shinzui/shibuya-pgmq-adapter.git
cabal check
cabal sdist shibuya-pgmq-adapter
```

The focused test command must end with zero failures. The benchmark transcript must report
read count as well as time so the 100-group fixture visibly uses fewer reads at quantities 10
and 50 than at quantity one.


## Validation and Acceptance

The implementation is accepted only when all six standard/long-poll strategy dispatches are
covered; a database request larger than the number of groups never leases two members of one
group; an invisible or delayed head blocks its successor but not another group; deleting a
head advances that group; the safe-drain benchmark meets the 20 percent gate and materially
reduces statements for multi-group fixtures; all components build; strict capability
validation passes; and 0.16.0.0 (or the correctly recomputed PVP version) is available from
both Hackage and an upstream `v<version>` tag.

As mutation evidence, temporarily dispatch `HeadPerGroup` through `readGrouped` and confirm
the at-most-one-member integration assertion fails, then restore the correct branch before
committing. Temporarily force grouped-head quantity one and confirm the multi-group statement
count guard fails or loses its expected reduction.


## Idempotence and Recovery

Source edits, formatting, ephemeral-database tests, and benchmark fixture setup are repeatable.
The benchmark must never target a production database. If interrupted, recreate the disposable
database with the repository's process workflow or drop only the explicit `bench_fifo_*`
queues.

Hackage versions and git tags are immutable. Verify the version, clean worktree, signed-in
credentials, and sdist before publishing. If an upload reports that the version already
exists, stop and inspect Hackage instead of retrying or inventing another version. If the
benchmark gate fails, leave the release milestone incomplete and retain diagnostic evidence.


## Interfaces and Dependencies

The public addition in `Shibuya.Adapter.Pgmq.Config` is:

```haskell
data FifoReadStrategy
  = ThroughputOptimized
  | RoundRobin
  | HeadPerGroup
```

`HeadPerGroup` maps to released `Pgmq.Effectful.readGroupedHead :: ReadGrouped -> Eff es
(Vector Message)` for standard polling and `readGroupedHeadWithPoll :: ReadGroupedWithPoll ->
Eff es (Vector Message)` for long polling. No PGMQ SQL, migration, Shibuya core scheduler, or
dependency-family version changes belong to this plan. The adapter package alone is published;
the example and benchmark packages remain repository-only.
