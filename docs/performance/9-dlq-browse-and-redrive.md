# DLQ administration performance evidence

Plan: [ExecPlan 9](../plans/9-expose-adapter-managed-dead-letter-queue-browse-and-redrive.md).

Status: **release validation completed; numeric performance check failed**.
The corrected FIFO experiment completed all seven triplets (21 new measurements),
reused 344 unchanged measurements, and recomputed all 198 gates: **196 PASS,
2 FAIL**. Both failures are FIFO acknowledgement p95 upper bounds: original
1.106857 and matched 1.172465, against the unchanged 1.10 limit. Paired median
ratios are respectively 1.026316 and 0.899244. The smaller fixture fixed sampling
cost but did not establish the required latency bounds; calling it a solution
to latency variation was premature.

The [gate snapshot](9-dlq-browse-and-redrive-gates.json) records every actual
result, prior fixture results, source hashes and dependency identities. The full
result is `.dev/dlq-release-validated-fifo/result.json`. All 192 unaffected gates
are identical to their previously retained results. Background Finder, XProtect
and Spotlight activity was observed during the later samples; its contribution
was not isolated, so it is not a proven explanation or a basis for discarding
samples. No further benchmark experiment or budget waiver is claimed.

The measured candidate is `d4dfba17d0be431ed6b7f7e30ad7f8722b4166d8`,
using released PGMQ 0.7.0.0 and Shibuya core 0.12.0.0. Subsequent changes affect
orchestration, acceptance tests and documentation; frozen Haskell/Cabal/Nix
source hashes are verified before evidence reuse. The final combined result must
pass all 198 original numeric gates. Separate pools alone do not establish
performance isolation. Partitioned queues are outside the validated matrix.

The runner now supports a full experiment and exact-sample resumption. The
one-off worker/encoding extension commands below describe historical evidence
created with commit `6e99c40`; they are no longer current CLI options. To select
21 encoding pairs upfront, pass `--encoding-pairs 21` to the full runner.
Cleanup preserved every recorded result and all numeric limits.

The current runner corrects the oversized `ack-fifo` source fixture to 500,000
rows for all three variants. Its full-duration validation collected 46,455
acknowledgements with 445,360 rows remaining; details are under “FIFO fixture
correction” below. The complete result tables preserve the historical
three-million-row configuration and are not rewritten by this fixture change.

## Retained complete result

| Gate family | Passed / required |
|---|---:|
| Worker controls, including idle handle | 43 / 45 |
| Four fixed-rate operator-load comparisons | 8 / 8 |
| Encoding timing and allocation | 60 / 60 |
| Adapter versus raw reads | 60 / 60 |
| Tenfold queue-depth scaling | 24 / 24 |
| Five-minute retained heap | 1 / 1 |
| Total | **196 / 198** |

Confidence bounds use 10,000 bootstrap resamples of paired medians with seed
910262026. Throughput ratios are control/candidate; latency ratios are
candidate/control. Encoding, allocation and adapter-read ratios are normalized
by their specified combined allowances, so their limit is one. The snapshot
retains each individual workload rather than averaging percentiles across cases.
The encoding matrix and `ack-one` use 21 pairs; other completed cases use seven.

All 18,480 scheduled administrative calls completed successfully across the 28
loaded runs, with zero failures and a drained backlog. Each run achieved one
redrive/second. The following ranges show the smallest/largest per-run
scheduled-arrival redrive percentiles, not pooled or averaged percentiles:

| Four-worker workload | Redrive p50 range (ms) | Redrive p95 range (ms) |
|---|---:|---:|
| Ordinary, batch 1 | 0.812–1.090 | 1.450–1.529 |
| Ordinary, batch 50 | 2.052–2.680 | 3.199–3.344 |
| FIFO, batch 1 | 2.776–3.035 | 3.282–3.355 |
| FIFO, batch 50 | 2.848–3.056 | 3.300–3.376 |

All required actual read plans use message-ID index access without full-table
scans or sorts. The five-minute large-page run processed 3,360 pages; median
retained-heap growth was 565,712 bytes against the 8,388,608-byte allowance.
Peak residency was 50,602,176 bytes and median allocation per page was
104,248,639.5 bytes. JSONB `pg_column_size` observations and CPU/I/O counters are
retained in the raw run artifacts separately from compact-JSON byte assertions.

These results use the disposable database configuration below, including
`fsync=off`, `synchronous_commit=off` and controlled fixture maintenance. They
establish no production SLO or arbitrary-load isolation guarantee.

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

## Acceptance protocol

The released PGMQ 0.7.0.0 family is adopted and the temporary administration
flag has been removed. The full `scripts/check-dlq-performance.py` acceptance
orchestrator is implemented. It retains both the original dependency baseline
and a matched released-dependency control; neither the local 0.7.0.0 integration
proof nor the single baseline sample replaces these controls.

The matrix implements every numeric budget in plan 9: initialization with an
idle administration handle and a separate no-handle control, dedicated encoding
allocations, fixed-rate successful operator traffic with scheduled-arrival
latency/backlog counts, 100k/1m ordinary and unlogged read fixtures, raw-read
controls and actual query plans, and five-minute retained-heap measurements.
Retain every paired run and confidence bound. Failed or inconclusive budgets
leave M4 open; none may be relaxed without the user's scope decision.


## Released-candidate implementation checkpoint

The unflagged PostgreSQL suite passes 203 examples, including 20 administration
scenarios, with PGMQ 0.7.0.0 and Shibuya core 0.12.0.0. All components build in
`dist-dlq-release` and Haddock succeeds. Thirteen Python tests protect acceptance
ratios and fail-closed evidence checks. These are correctness/tooling evidence.
The final retained performance result has one unresolved gate.

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
in `docs/friction-log/`. The system SDK `_time.h` declares the API. The GHC 9.12.4 timing implementation
(project `mori://ghc/ghc`, tag `ghc-9.12.4-release`, path
`rts/posix/GetTime.c`; artifact-level URI pending) selects the platform monotonic
clock when available.

`PerformanceClock` now supplies the raw monotonic clock on Darwin, with the GHC
clock elsewhere. The same module is applied to both worker controls and the
candidate. No old coarse-clock samples are reused. The short-latency `ack-one`
case has a fixed, predeclared 21 pairs (`--ack-one-pairs 21`); all other cases
retain seven pairs. All 21 must finish even if an earlier bound would pass.
The original minimum is seven; budgets and per-run durations are unchanged.
The fine-clock candidate check observed 0.030959ms p95 with one-nanosecond common
divisor across its recorded deltas; it is diagnostic, not acceptance.


## Fine-clock parent experiment

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
original/matched/candidate samples completed. The worker controls completed; the parent subsequently stopped as INCONCLUSIVE
because the batch-one FIFO operator fixture supplied too few observations.
The resumption below preserves all valid measurements, including failed bounds.


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
  --extend-worker-from .dev/dlq-release-encoding-extension \
  --worker-scenario ack-fifo --worker-pairs 21 \
  --output .dev/dlq-release-fifo-extension
```

The extension refuses a running parent, changed measured Haskell/Cabal sources,
changed tools or hardware, missing pairs, and an existing output directory. Its
combined result keeps every unrelated parent gate, so it cannot turn another
failed or incomplete case into an overall PASS. The checker also enforces the
original operator success budget (at least 99%, with drained backlog); a boundary
test prevents accidentally requiring 100% success. No measurement is discarded.


## Operator fixture sample sufficiency and resumption

Both ordinary-worker operator-load cases passed. The original
`fifo-load-one` source fixture of 3,000,000 rows produced only 48–52 observations
per minute. Those 14 runs are retained as inconclusive; they cannot satisfy the
minimum 1,000 observations. The full parent stopped with INCONCLUSIVE rather than
accepting them or omitting the remaining cases.

Only that operator case now uses a 100,000-row source, retaining the prescribed
100,000-row DLQ, 1-KB source bodies, four workers, batch size one, four/two pool
connections and 5 browse / 5 fetch / 1 redrive calls per second. Source count was
not fixed by the plan. The full-duration check in
`.dev/dlq-fifo-one-fixture-check.json` recorded 1,532 observations, 98,270 remaining
rows and 660 successful calls. It is diagnostic, not a paired acceptance run.
The three-million-row `ack-fifo` worker data remain unchanged.

```bash
nix develop --no-write-lock-file -c python3 scripts/check-dlq-performance.py \
  --baseline-ref e06e64b268055aca4eff78caabd1b0eb73aa1cd1 \
  --resume-from .dev/dlq-release-fine-clock \
  --case-seed-count fifo-load-one=100000 \
  --output .dev/dlq-release-resumed
```

Resumption verifies the frozen code, constraints, tools and hardware, references
all matching measurements by exact argument vector and case/pair identity, and
retains failures instead of rerunning them. Changed fixture arguments receive
new measurements. All parent evidence remains intact, and every required gate
is recomputed over its complete prescribed pairs. The resumed parent completed 337 logical measurement entries and all 198 gates:
188 passed, with FIFO worker p95 and nine encoding time bounds unresolved.
The complete encoding extension below then became the FIFO extension parent.


## Fixed complete encoding extension

All allocation gates and exact source-field byte checks pass. Nine of the 30
time bounds cross their normalized limit of one; every affected median remains
within budget. All original seven pairs remain retained. Before additional
collection, fix the complete encoding matrix at exactly 21 pairs, adding every
one of the 14 further pairs across all reasons, metadata modes and body sizes.
The shared evaluator exactly reproduces the original 60 gate results.

After the resumed parent finishes, run:

```bash
nix develop --no-write-lock-file -c python3 scripts/check-dlq-performance.py \
  --baseline-ref e06e64b268055aca4eff78caabd1b0eb73aa1cd1 \
  --extend-encoding-from .dev/dlq-release-resumed --encoding-pairs 21 \
  --output .dev/dlq-release-encoding-extension
nix develop --no-write-lock-file -c python3 scripts/check-dlq-performance.py \
  --baseline-ref e06e64b268055aca4eff78caabd1b0eb73aa1cd1 \
  --extend-worker-from .dev/dlq-release-encoding-extension \
  --worker-scenario ack-fifo --worker-pairs 21 \
  --output .dev/dlq-release-fifo-extension
```

Each stage preserves the preceding complete result and every unrelated gate,
links verified immutable source/binaries/dependency evidence, and retains initial
bounds in `supersededGates`. A stage reporting FAIL may still carry an unrelated
unresolved gate; the final combined result must pass all 198. No further sample
extension or changed limit is authorized by this declaration.


## Complete encoding result and final FIFO reassessment

The complete fixed 21-pair encoding matrix finished with every timing,
allocation and exact compact-JSON byte-growth check passing. The combined result
in `.dev/dlq-release-encoding-extension/result.json` retains 365 logical
measurement entries and passes 197 of 198 gates. Its only unresolved gate is
`ack-fifo/original/p95` from the original seven worker pairs.

The FIFO extension in `.dev/dlq-release-fifo-extension/` used that complete
encoding result as parent. It was interrupted after three completed additional
measurements to honor immediate finalization. Its result is INCONCLUSIVE and
all files are retained. The declared 21-pair reassessment has not completed;
do not mix its partial samples into acceptance or claim an overall PASS.
Completing plan 9 still requires a complete fixed experiment meeting the
original gate, or an explicit user decision to defer performance acceptance.


## Final implementation checks

After stopping the FIFO extension, the fresh O1 build directory
`dist-dlq-release-final` built every component and passed the full unflagged
suite: 203 examples, zero failures. Thirteen Python acceptance-checker tests and
all three changed OKF bundle profile/log validations pass. Final build/test/
Haddock logs are `.dev/dlq-release-final-{build,test,haddock}.log`.
These checks complete the implementation handoff; they do not waive the one
remaining numeric performance gate.


Maintenance cleanup removed the one-off sample-extension workflow while keeping
the full matrix and exact-sample resumption. All 12 remaining checker tests pass.
A replay in `.dev/dlq-cleanup-replay/` reused all 365 saved measurements and
reproduced all 198 gate records exactly, with benchmark/build children forbidden.
The recorded FIFO failure remains; no performance result changed.


## Bounded FIFO latency investigation

The failing metric measures only `message.ack.finalize AckOk`, excluding dequeue.
The adapter's successful-acknowledgement implementation is unchanged from the
pre-feature source: it serializes finalization, retries transient failures, and
calls `deleteMessage`. Source-envelope encoding executes only for dead letters;
constructing the idle admin handle starts no queries or threads. The dependency
upgrade preserves the successful delete statement and grouped-head SQL (project
`mori://shinzui/pgmq-hs`, tags `v0.6.1.1` and `v0.7.0.0`, paths
`pgmq-hasql/src/Pgmq/Hasql/Statements/Message.hs` and
`pgmq-migration/migrations/0004-upgrade-v1.12.0.sql`; artifact-level URIs pending).

Across the seven complete FIFO runs, median per-run acknowledgement p50 is
31.083 microseconds original, 30.833 matched, and 30.958 candidate. Original
p95 alone ranges from 40.208 to 51.250 microseconds. The candidate/matched paired
p95 median ratio is 0.981830 (upper95 1.077294). Candidate/original has median
1.082919 and bootstrap median percentiles 5/95 of 0.941245/1.136174. Thus the
complete data neither establish a positive p95 increase at the one-sided 95%
level nor establish the required upper bound of 1.10. Calling the upper bound
itself a measured 13.6% regression was incorrect. The original gate remains FAIL.

The expensive worker operation is the existing grouped-head dequeue: its
`GROUP BY`/`MIN(msg_id)` computes heads over the whole source queue before
limiting selected heads. All three controls scan the three-million-row fixture,
yielding only about 133–141 original acknowledgements/second. The fixture omits
`createFifoIndex`, but that helper creates a GIN index on headers, which cannot
serve this grouping expression. A disposable 100k-row EXPLAIN diagnostic confirms
both with/without-GIN plans use a sequential scan of all 100k rows. Its complete
plans are `.dev/dlq-fifo-query-diagnostic-fixed.log`. Do not infer an index speedup
from those sequential observations; their cache state differs.

This identifies an existing dequeue bottleneck and excessive fixture cost; it
does not prove that scans caused the small acknowledgement-tail difference.
That difference remains consistent with run variation, with no production DLQ
regression isolated. The four short original-binary diagnostics in
`.dev/dlq-fifo-aa-diagnostic/` depleted their 100k-row queues and all report
`valid=false`; they are excluded from quantitative conclusions. No acceptance
matrix was rerun, no production source changed, and no numeric limit was waived.


## FIFO fixture correction

The benchmark's default `ack-fifo` source count was excessive. Grouped-head
selection scans the whole source before choosing heads; three million rows
produced only about 8,400 acknowledgement samples per minute. Change the default
to a fixed 500,000 rows, identically for original, matched and candidate. The
source count was not prescribed by plan 9. Keep the four workers, 50-row batch,
100 groups, 10-KB bodies, pools, warmup/sample durations and all numeric limits.
Existing exact-argument resumption cannot reuse the old larger-fixture samples.

A fixed three-way diagnostic at two seconds warmup and fifteen seconds sampling
produced 12,816 / 12,664 / 12,563 original/matched/candidate acknowledgements,
with valid nondepleted queues. Their p95 values were respectively
39.458 / 44.166 / 43.334 microseconds. A candidate validation at the prescribed
ten-second warmup and sixty-second sample produced **46,455 observations**,
**445,360 remaining rows**, p95 **42.375 microseconds**, and `valid=true`.
This fixes unnecessary fixture cost and sample starvation without a production
change. These targeted checks validate the fixture, not bootstrap acceptance of
a new complete paired matrix. All 12 checker tests pass; no full matrix was rerun.
Artifacts and exact arguments are retained in `.dev/dlq-fifo-focused/`.


Final handoff validation: all components build, the PostgreSQL suite passes
203 examples with zero failures, all 12 checker tests pass, and `cabal check`
reports no errors or warnings. Logs are `.dev/dlq-release-validation-build.log`
and `.dev/dlq-release-validation-test.log`. Production source is unchanged from
the measured candidate. These correctness/package checks do not turn the two
failed numeric bounds into passes. Benchmark work has stopped.
