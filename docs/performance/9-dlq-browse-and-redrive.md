# DLQ administration performance evidence

Plan: [ExecPlan 9](../plans/9-expose-adapter-managed-dead-letter-queue-browse-and-redrive.md).

Status: **incomplete**. The fine-clock experiment has passed all six `ack-one`
gates across the complete, predeclared 21 pairs. The rest of the matrix remains
in progress; no overall performance PASS is claimed. PGMQ 0.7.0.0 now supplies the released
inspection dependency. The complete paired candidate,
matched-dependency, administrative-load, large-queue, allocation and retained-heap
matrix has not been measured. Ordinary, unlogged and partitioned queues have no
validated performance budget from this work yet. Correctness tests and the
serialization benchmark do not establish performance isolation.

## Preserved original control

Before production feature edits, export commit
`e06e64b268055aca4eff78caabd1b0eb73aa1cd1` into
`.dev/dlq-performance/baseline-source` using `git archive`. Apply only the new
worker executable's Cabal component and its two instrumentation modules. The
exact initial instrumentation diff is retained at
`.dev/dlq-performance/initial-instrumentation.patch`; it predates the later
capture script and its additional environment reporting. The production adapter
source in that export is unchanged.

The initial original-dependency run used:

```bash
nix develop --no-write-lock-file -c cabal run dlq-performance \
  --project-dir=.dev/dlq-performance/baseline-source \
  --builddir=dist-baseline --enable-optimization=2 -- \
  ack-one 10 60 1000000 +RTS -N4 -T -RTS
```

The runner created its own disposable PostgreSQL database, installed PGMQ and
seeded 1,000,000 original messages before starting a real `pgmqAdapter` worker.
Each body carried a 100-character ASCII string inside an object (111 compact JSON
bytes); this initial fixture is not the final matrix's exact 100-byte body. Finalization was `AckOk`, batch
size one, one worker and four pool connections. The sample excludes setup,
seeding and the ten-second warmup. A latency observation ends after the adapter
finalizer returns, including confirmed acknowledgement. Completions are measured
separately from handler invocations. Runtime allocation totals cover the measured
worker interval, including common instrumentation; they are not encoding-loop
allocation evidence.

| Initial observation | Result |
|---|---:|
| Measured duration | 60.040458 seconds |
| Committed observations | 245,678 |
| Committed throughput | 4,091.874 messages/second |
| Finalization p95 | 0.098 milliseconds |
| Allocated bytes per measured commit | 40,452.800 |
| Rows left at completion | 659,606 |

Artifacts retain all latency observations in
`.dev/dlq-performance/baseline-ack-one.json`, original build/run output in
`.dev/dlq-performance/baseline-ack-one.log`, and the exact resolved dependencies in
`.dev/dlq-performance/baseline-source/dist-baseline/cache/plan.json`.
The initial sample is a diagnostic original-worker baseline, not a paired
comparison: there are no candidate ratios, bootstrap bounds or passing budgets
to report.

Environment: Apple M5 Ultra (`Mac17,15`), 274,877,906,944 bytes physical memory,
`aarch64-osx`, GHC 9.12.4, Cabal 3.16.1.0, library optimization `-O2`, executable
`-O2`, runtime `-N4 -T`, PostgreSQL 18.6. The initial runner did not retain
PostgreSQL settings; the current runner now records server version, buffers,
work memory, durability settings and connection limits before timing. This
missing initial environment detail is another reason the sample cannot stand
in for final acceptance.

The initial plan resolved the [PGMQ family](mori://shinzui/pgmq-hs) packages
`pgmq-core`, `pgmq-hasql`, `pgmq-effectful` and
`pgmq-migration` to 0.6.1.1, [`shibuya-core`](mori://shinzui/shibuya/packages/shibuya-core) to 0.11.0.0,
[`effectful-core`](mori://effectful/effectful/packages/effectful-core) to
2.7.1.2, [Hasql family](mori://hasql/hasql) packages `hasql` to 1.10.3.7,
`hasql-pool` to 1.4.2.3,
`hasql-transaction` to 1.2.3.1 and `aeson` to 2.2.5.1.

## Reproducible worker control capture

The shared runner uses only the pre-feature public worker API. The capture
script exports the selected commit into an isolated output directory, applies
identical instrumentation, builds with optimization, and retains a source patch,
instrumentation hashes, compiler/hardware information, the complete dependency
plan, database settings, raw observations and per-run summaries. It never accepts
a database connection or uses a persistent application database. Each Haskell
child scopes and stops its disposable PostgreSQL instance; the orchestrator
interrupts only its own child process group on cancellation. Existing output
directories are refused to preserve failed and inconclusive evidence.

```bash
nix develop --no-write-lock-file -c python3 scripts/capture-dlq-worker-baseline.py \
  --baseline-ref e06e64b268055aca4eff78caabd1b0eb73aa1cd1 \
  --output .dev/dlq-worker-control --repetitions 7 --seed-count 3000000
```

Defaults are ten seconds warmup and sixty seconds measurement, with all seven
worker scenarios from plan 9. Fewer than 1,000 observations, queue depletion or
child failure makes capture inconclusive and exits nonzero. Choose an adequate
fixture size before beginning the fixed experiment; retain every run. Run on an
otherwise idle machine. This command captures only the original dependency
control, not paired candidate comparisons or any administration workloads.

The capture script itself was exercised end to end with the final exact-size
worker fixture:

```bash
nix develop --no-write-lock-file -c python3 scripts/capture-dlq-worker-baseline.py \
  --baseline-ref e06e64b268055aca4eff78caabd1b0eb73aa1cd1 \
  --scenario ack-one --output .dev/dlq-worker-capture-check
```

It exited zero with `BASELINE-CAPTURE: COMPLETE (original worker control only;
not performance acceptance)`. Its one 60.039293-second measured sample contains
293,551 committed observations, 4,889.315 messages/second, finalization p95
0.056ms, 39,682.722 allocated bytes per commit and 634,351 remaining rows.
This run validates orchestration and retained evidence, not a regression ratio.
The fixture differs from the initial diagnostic by using an exactly 100-byte
compact JSON string; do not pair these two initial samples with each other.

All raw data, immutable source export, instrumentation patch/hashes and dependency
identities are retained under `.dev/dlq-worker-capture-check/`. `environment.json`
records macOS 27.0.1, arm64, 36 logical CPUs, GHC 9.12.4, PostgreSQL 18.6 and the
hardware listed above. `ack-one-1.json` records `shared_buffers=12MB`,
`work_mem=4MB`, `max_connections=100`, **`fsync=off` and
`synchronous_commit=off`**, the disposable database helper's defaults. These are
confirmed database operations in that configuration, not production durability
or production SLO measurements. Keep the complete PostgreSQL configuration fixed
between future controls and candidates and record it explicitly.

## Serialization diagnostics

`shibuya-pgmq-adapter-bench/bench-dlq/Main.hs` now compares the current dual-write
helper with `mkDlqPayloadForQueue` over both metadata modes, all reason
constructors, 100/10,000/100,000-byte compact JSON string bodies and an additional 8-KiB
application-detail case. Every case checks that the compact JSON byte increase
equals exactly the source field contribution, independently of body/detail size.
For source `orders`, that contribution is 26 bytes. PostgreSQL JSONB storage uses
a different representation and is not established by this compact JSON check.

```bash
nix develop --no-write-lock-file -c cabal bench \
  shibuya-pgmq-adapter-bench:bench:dlq-payload-bench --benchmark-options='--stdev 10'
```

The final diagnostic run is retained at `.dev/dlq-payload-bench.log`, using the
10% tasty-bench deviation setting because timing is diagnostic here. The earlier
default-deviation run with 100/10,000/100,000-character bodies is retained at
`.dev/dlq-payload-bench-initial.log`; it is not the exact-size final matrix. Neither is the
required dedicated repeated-encoding allocation loop or bootstrap comparison.

## Remaining acceptance

The released PGMQ 0.7.0.0 family is adopted and the temporary administration
flag has been removed. The full `scripts/check-dlq-performance.py` acceptance
orchestrator is implemented. It retains both the original dependency baseline
and a matched released-dependency control; neither the local 0.7.0.0 integration
proof nor the single baseline sample replaces these controls.

Run the entire matrix and numeric budgets in plan 9, including initialization
with an idle administration handle, the no-handle comparison, dedicated encoding
allocations, fixed-rate successful operator traffic with scheduled-arrival
latency/backlog counts, 100k/1m ordinary and unlogged read fixtures, raw-read
controls and actual query plans, and five-minute retained-heap measurements.
Retain all paired runs and confidence bounds. Failed or inconclusive budgets
leave M4 open; none may be relaxed without the user's scope decision.


## Released-candidate implementation checkpoint

The unflagged PostgreSQL suite passes 203 examples, including 20 administration
scenarios, with PGMQ 0.7.0.0 and Shibuya core 0.12.0.0. All components build in
`dist-dlq-release` and Haddock succeeds. Ten Python tests protect acceptance
ratios and fail-closed evidence checks. These are correctness/tooling evidence.
The full measured acceptance result remains pending.

The runner exports immutable source controls; the matched control's retained
compatibility patch upgrades family constraints and populates the new
`Ingested.deliveryStatus = pure DeliveryCurrent` field. It compares resolved
shared dependency versions before measuring. Original-source production code
receives no compatibility changes. Candidate comparisons initialize an idle
administration handle, with a separate no-handle control. Read cases retain
per-position/limit observations rather than pooling different workloads.

Short smoke runs use fresh `.dev/dlq-smoke-20261026*` directories. Initial failed
smokes exposed control-constraint and near-tail fixture mistakes in the new
tooling; their logs remain available. Smoke mode always reports INCONCLUSIVE,
including when every diagnostic executes successfully. It cannot produce PASS.


The first full attempt, `.dev/dlq-release-25cb519/`, was interrupted after eight
completed worker samples. Review found that the common instrumentation excluded
background redrives by a fixture payload marker rather than the plan's explicit
source-ID boundary. The corrected instrumentation uses the source message ID
(`CursorInt`), counting only the originally seeded IDs. This changes common
measurement code, so the initial samples remain diagnostic and are not reused
for acceptance. The fixed pre-feature source commit is unchanged.


## First complete case and fixture-maintenance investigation

The ID-based attempt `.dev/dlq-release-id-counted/` completed all seven pairs for
`ack-one`. Its upper cost bounds failed: original throughput 1.081977, matched
throughput 1.085166 (budget 1.052632), and original p95 1.303030 (budget 1.10).
All three allocation gates passed. Every sample is retained. These results do
not establish acceptance, and the user reaffirmed retaining the original gates.

The short `.dev/dlq-scheduler-diagnostic/` runs compare original/candidate binaries
with one and four capabilities. All eight observed about 9,000 messages/second
and 0.028ms p95 over ten seconds; scheduler capabilities did not explain the
failure. These short runs cannot replace the required sixty-second samples.

A subsequent read-only diagnostic of the owned disposable database found an
active `VACUUM ANALYZE` during a measured worker interval, 1,308,804 estimated
dead tuples, and two requested checkpoints with only one completed. The complete
query output is `.dev/dlq-autovacuum-diagnostic.log`. Automatic maintenance timing
was not controlled by merely excluding seeding from timed work. See PostgreSQL's
[maintenance statistics](https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-PG-STAT-ALL-TABLES-VIEW)
and [CHECKPOINT semantics](https://www.postgresql.org/docs/18/sql-checkpoint.html).

The corrected setup disables automatic vacuum/analyze **only on disposable
benchmark queues**, manually vacuums/analyzes the seeded fixtures and completes a
checkpoint before warmup. It applies unchanged to both worker controls and the
candidate. Results retain table options and automatic/manual maintenance counts;
uncontrolled preparation is inconclusive. This is a controlled database
configuration, not a production maintenance recommendation or a production SLO.
The budgets, workload sizes/rates, pools, durations and runtime capabilities are
unchanged. All comparisons must restart after this common instrumentation change;
no favorable subset of the earlier samples is reused.


## Clock precision and fixed sample counts

The first stabilized seven-pair case passed five of six gates. Only matched p95
remained unresolved (upper bound 1.107142857; budget 1.10). Its recorded durations
were all multiples of 1000ns. A direct 100,000-read diagnostic confirmed the GHC
runtime timer's 1000ns quantization on this host; Darwin
`clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` instead observed 41/42ns steps.
Retain `.dev/check-dlq-clock.log` and the failed stabilized attempt, and see FRIC-3
in `docs/friction-log/`. The system SDK `_time.h` declares the API, and the
[GHC 9.12.4 timing implementation](https://raw.githubusercontent.com/ghc/ghc/ghc-9.12.4-release/rts/posix/GetTime.c)
selects the platform monotonic clock when available.

`PerformanceClock` now supplies the raw monotonic clock on Darwin, with the GHC
clock elsewhere. The same module is applied to both worker controls and the
candidate. No old coarse-clock samples are reused. The short-latency `ack-one`
case has a fixed, predeclared 21 pairs (`--ack-one-pairs 21`); all other cases
retain seven pairs. All 21 must finish even if an earlier bound would pass.
The original minimum is seven; budgets and per-run durations are unchanged.
The fine-clock candidate check observed 0.030959ms p95 with one-nanosecond common
divisor across its recorded deltas; it is diagnostic, not acceptance.


## Active final-candidate experiment

Candidate `d4dfba1`, unchanged shared raw-clock instrumentation, released
dependencies, fixed original source `e06e64b268055aca4eff78caabd1b0eb73aa1cd1`:

```bash
nix develop --no-write-lock-file -c python3 scripts/check-dlq-performance.py \
  --baseline-ref e06e64b268055aca4eff78caabd1b0eb73aa1cd1 \
  --pairs 7 --ack-one-pairs 21 --warmup-seconds 10 --sample-seconds 60 \
  --output .dev/dlq-release-fine-clock
```

Artifacts: `.dev/dlq-release-fine-clock/`; top-level progress log:
`.dev/dlq-release-fine-clock.log`. All six `ack-one` gates passed after all 63
original/matched/candidate samples completed. Other worker, operator-load,
encoding, read-depth and retention gates are still pending. `result.json` is the
machine-readable running result, not a complete acceptance certificate.


FIFO's first seven pairs passed five of six gates; original-control p95 remained
unresolved (median 1.082919, upper bound 1.136174, limit 1.10). A single extension
to a fixed 21 total pairs is declared before additional data collection. All
seven original pairs remain included. After the parent experiment finishes,
run the following once; it reuses verified immutable binaries and identical
settings, adds all 14 further pairs and retains the initial gates alongside the
final all-pairs reassessment:

```bash
nix develop --no-write-lock-file -c python3 scripts/check-dlq-performance.py \
  --baseline-ref e06e64b268055aca4eff78caabd1b0eb73aa1cd1 \
  --extend-worker-from .dev/dlq-release-fine-clock \
  --worker-scenario ack-fifo --worker-pairs 21 \
  --output .dev/dlq-release-fifo-extension
```

The extension refuses a running parent, changed measured Haskell/Cabal sources,
changed tools or hardware, missing pairs, and an existing output directory. Its
combined result keeps every unrelated parent gate, so it cannot turn another
failed or incomplete case into an overall PASS. The checker also enforces the
original operator success budget (at least 99%, with drained backlog); a boundary
test prevents accidentally requiring 100% success. No measurement is discarded.
