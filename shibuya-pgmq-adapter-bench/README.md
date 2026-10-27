# shibuya-pgmq-adapter-bench

Comprehensive benchmarks for `shibuya-pgmq-adapter` using [tasty-bench](https://hackage.haskell.org/package/tasty-bench).

## Prerequisites

- PostgreSQL. The benchmark harness installs the pgmq schema itself on startup
  (`BenchSetup.installPgmqSchema`, via `pgmq-migration`'s `pg-migrate` component), so a plain
  database is enough. Re-running against an already-migrated database is a no-op.
- `PG_CONNECTION_STRING` environment variable set

A benchmark database created before the `pgmq-migration` 0.4 upgrade still carries a
`public.schema_migrations` ledger, which the native runner does not read and will not install over.
The quickest fix for a throwaway benchmark database is to drop the `pgmq` schema and
`public.schema_migrations` and let the harness reinstall; to preserve it, import the ledger as
described in [Installing the PGMQ
schema](../docs/user/pgmq-getting-started.md#installing-the-pgmq-schema).

## Running Benchmarks

### 1. Start PostgreSQL

If using the project's process-compose:

```bash
just process-up
```

Or start PostgreSQL manually and ensure the database exists.

### 2. Set Connection String

The benchmarks require a PostgreSQL connection string:

```bash
# For unix socket (typical local development)
export PGHOST="$PWD/db"
export PGDATABASE=shibuya
export PG_CONNECTION_STRING="postgresql:///shibuya?host=$(jq -rn --arg x "$PGHOST" '$x|@uri')"

# Or for TCP connection
export PG_CONNECTION_STRING="postgresql://localhost:5432/shibuya"
```

### 3. Run Benchmarks

```bash
# Run all benchmarks
cabal bench shibuya-pgmq-adapter-bench

# Run with custom settings
cabal bench shibuya-pgmq-adapter-bench --benchmark-options="--stdev 10"

# Run specific benchmark patterns (uses tasty pattern matching)
cabal bench shibuya-pgmq-adapter-bench --benchmark-options="-p send"
```

## Configuration

Environment variables for customizing benchmark behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `PG_CONNECTION_STRING` | (required) | PostgreSQL connection string |
| `BENCH_MESSAGE_COUNT` | 1000 | Number of messages for throughput tests |
| `BENCH_BATCH_SIZES` | 1,10,50,100 | Batch sizes to benchmark |
| `BENCH_QUEUE_COUNT` | 4 | Number of queues for multi-queue tests |
| `BENCH_CONCURRENCY` | 4 | Concurrent workers for concurrency tests |
| `BENCH_PAYLOAD_SIZES` | small,medium,large | Payload size variants |
| `BENCH_SAFE_FIFO_RUNS` | 3 | Drain-only samples collected for median and p95 in each safe FIFO matrix entry |
| `BENCH_SKIP_CLEANUP` | false | Skip queue cleanup after benchmarks |

## Benchmark Categories

### Send Benchmarks
- Single message send
- Batch sends (10, 100, 1000 messages)
- Send with headers / FIFO group headers
- Delayed sends (5s, 30s delay)
- Payload sizes (100B, 10KB, 100KB)

### Read Benchmarks
- Single message read
- Batch reads (10, 50, 100 messages)
- Polling operations

### Ack Benchmarks
- Delete (single and batch)
- Archive (single and batch)
- Visibility timeout updates
- Pop operations

### FIFO Benchmarks
- Grouped reads
- Round-robin reads
- Group count variations (1, 10, 100 groups)
- Complete safe drains compare legacy quantity one with grouped-head quantities 1, 10, and 50
  for the 10,000-message fixtures. The 100,000-message/10,000-group fixture compares grouped
  heads at quantities 10 and 50 with grouped-head quantity one; a legacy quantity-one drain at
  that cardinality requires 100,000 pathological scans and is intentionally excluded. Run the
  release matrix with `--stdev Infinity`; the benchmark performs its own repeated drain-only
  sampling and prints read count, median, p95, throughput, ratio, and gate result.

### Multi-Queue Benchmarks
- Round-robin send across queues
- Read from all queues
- Queue lifecycle (create/drop)
- Metrics collection

### Throughput Benchmarks
- Send-only (100, 1000 messages)
- Read-only (pop 100, 1000 messages)
- Full cycle (send-read-delete)
- Burst operations

### Concurrent Benchmarks
- Multiple readers (2, 4, 8)
- Multiple writers (2, 4, 8)
- Mixed read/write workloads
- Scaling tests

### Raw vs Effectful Comparison
- Direct pgmq-hasql vs effectful layer overhead
- Send, read, and ack operations compared

## Benchmark Results

Results from Apple M4 Max with PostgreSQL 17:

### Send Operations

| Benchmark | Time |
|-----------|------|
| Single send | 177 μs |
| Batch 10 | 203 μs |
| Batch 100 | 374 μs |
| Batch 1000 | 2.02 ms |
| With headers | ~200 μs |
| Small payload (100B) | ~180 μs |
| Medium payload (10KB) | ~190 μs |
| Large payload (100KB) | ~200 μs |

### Read Operations

| Benchmark | Time |
|-----------|------|
| Read single | ~30 ms |
| Read batch 10 | ~95 ms |
| Read batch 50 | ~100 ms |
| Read batch 100 | ~98 ms |
| Poll immediate | ~30 ms |

### Ack Operations

| Benchmark | Time |
|-----------|------|
| Delete single | ~102 ms |
| Delete batch 10 | ~88 ms |
| Delete batch 100 | ~95 ms |
| Archive single | ~110 ms |
| Archive batch 10 | ~90 ms |
| Pop single | ~114 ms |
| Pop batch 10 | ~105 ms |

### FIFO Operations

| Benchmark | Time |
|-----------|------|
| Read grouped 10 | ~1.37 s |
| Read grouped 50 | ~1.39 s |
| Round-robin 10 | ~84 ms |
| Round-robin 50 | ~98 ms |

### Throughput

| Benchmark | Time |
|-----------|------|
| Send 100 msgs | ~34 ms |
| Send 1000 msgs | ~97 ms |
| Batch send 1000 | ~27 ms |
| Pop 100 msgs | ~29 ms |
| Pop 1000 msgs | ~41 ms |
| Full cycle 100 | ~23 ms |
| Full cycle 1000 | ~54 ms |

### Concurrent Operations

| Benchmark | Time |
|-----------|------|
| 2 readers | ~110 ms |
| 4 readers | ~120 ms |
| 8 readers | ~172 ms |
| 2 writers | ~34 ms |
| 4 writers | ~34 ms |
| 8 writers | ~41 ms |
| 2r-2w mixed | ~122 ms |
| 4r-4w mixed | ~123 ms |

### Raw hasql vs Effectful Layer

| Operation | Raw hasql | Effectful |
|-----------|-----------|-----------|
| Send single | ~19 ms | ~20 ms |
| Batch send 100 | ~21 ms | ~22 ms |
| Read batch 10 | ~102 ms | ~123 ms |
| Delete | ~137 ms | ~105 ms |

The effectful layer adds minimal overhead (~5-20%) for most operations.

## Notes

- Read benchmarks include seeding the queue with messages before running
- Times include queue setup/teardown overhead for some benchmarks
- Results may vary based on PostgreSQL configuration and hardware
- FIFO grouped reads are significantly slower due to the additional ordering constraints

## DLQ worker controls and queue-aware serialization

`dlq-payload-bench` compares current and queue-aware DLQ serialization for both
metadata modes, all reason constructors, three body sizes and a large-detail
case. It checks the exact compact-JSON contribution of `original_queue`.

Plan 9's shared `app/DlqPerformance.hs` runner measures real adapter workers and
times finalization through returned acknowledgements. Capture an immutable
original-dependency control inside the Nix shell:

```bash
python3 scripts/capture-dlq-worker-baseline.py \
  --baseline-ref e06e64b268055aca4eff78caabd1b0eb73aa1cd1 \
  --output .dev/dlq-worker-control --repetitions 7 --seed-count 3000000
```

Run from the repository root on an otherwise idle machine. The script exports
source into a fresh directory, instruments only that snapshot, builds optimized
code, runs the seven worker cases sequentially in disposable PostgreSQL databases
and retains settings, dependency identities and all latency observations. It
refuses an existing output directory and fails on inconclusive capture. Increase
fixture size before fixing an experiment if workers would exhaust it. It never
accepts a production database connection.

This captures worker controls only. The complete released candidate/control,
operator-load, large-queue, encoding-allocation and retained-heap acceptance
orchestrator is documented below. See the [plan 9 evidence report](../docs/performance/9-dlq-browse-and-redrive.md)
for actual measurements and outstanding gates. No performance PASS is inferred
from correctness tests, serialization diagnostics or these initial controls.


### Complete DLQ administration acceptance

Run the full experiment sequentially on an otherwise idle machine:

```bash
nix develop --no-write-lock-file -c python3 scripts/check-dlq-performance.py \
  --baseline-ref e06e64b268055aca4eff78caabd1b0eb73aa1cd1 \
  --pairs 7 --warmup-seconds 10 --sample-seconds 60 \
  --output .dev/dlq-release-performance
```

The script preserves immutable original, matched-dependency and current-source
snapshots, instrumentation/compatibility patches, dependency plans, hardware and
runtime settings, raw samples, actual query plans and `result.json`. Each run
uses its own disposable database and separate four-connection worker and
two-connection administration pools. It never accepts an application connection.
The complete matrix takes several hours. Keep the machine idle throughout.

`DLQ-PERFORMANCE: PASS` requires all plan 9 numeric gates. Missing evidence,
worker failure, queue depletion, an omitted comparison or an inconclusive bound
exits nonzero. Output directories cannot be reused. Preserve every failed run;
fix an identified cause before repeating affected comparisons.

For an orchestration diagnostic, use `--smoke --pairs 1 --warmup-seconds 0
--sample-seconds 1 --seed-count 20000` with a fresh output directory. Smoke mode
always reports `INCONCLUSIVE` and exits nonzero; it cannot certify acceptance.
The gate logic is checked with `python3 -m unittest discover -s scripts -p
test_dlq_performance.py`. No partitioned-queue performance budget is asserted.


Benchmark queues have automatic vacuum/analyze disabled only for the lifetime
of their disposable database. Fixture preparation performs manual vacuum/analyze
and a checkpoint before warmup so seed-triggered maintenance does not overlap
paired intervals unpredictably. Worker artifacts retain maintenance settings and
counters, and the acceptance checker rejects missing or uncontrolled setup. This
controlled configuration is not a production database maintenance recommendation.


The single-worker `ack-one` case uses a fixed 21 pairs by default
(`--ack-one-pairs 21`) because its latency budget is only a few microseconds;
other cases use `--pairs` (minimum seven). The count is chosen before measurement
and never shortened after a favorable bound. On Darwin, shared benchmark
instrumentation uses `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` rather than the
host runtime's microsecond-quantized clock. Other platforms retain the GHC clock.


For a fixed-count worker extension, use `--extend-worker-from <finished-output>
--worker-scenario <case> --worker-pairs <fixed-total>` with a new `--output`.
Declare the total before collecting additional observations. The checker retains
all previous pairs, verifies unchanged measured source/tool/hardware identities,
reuses immutable binaries, and recomputes the selected case over the entire data
set. It refuses a running parent to preserve sequential measurements and retains
all unrelated gates and the superseded initial bounds in the combined result.
