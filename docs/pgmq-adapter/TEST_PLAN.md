# PGMQ Adapter Test Plan

> This document previously held a large, hand-maintained test plan that drifted
> out of sync with the code (it described a Tasty suite the project no longer
> uses, a pre-`PgmqAdapterEnv` API, and test files that no longer exist). It has
> been replaced by this pointer: the executable test suite is the source of
> truth, and the reference docs below describe current behavior.

## The live test suite is authoritative

The HSpec suite under `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/` is the
canonical description of expected behavior. It runs against an ephemeral
PostgreSQL instance (started by the suite itself via `TmpPostgres`, no external
database required):

| Spec | Focus |
|------|-------|
| `ConvertSpec.hs` | Pure conversions: message ids, cursors, envelope construction, DLQ payloads. |
| `ConfigSpec.hs` | `validateConfig` rules and configuration defaults. |
| `InternalSpec.hs` | Ack-path mapping and internals via a stub `Pgmq` interpreter. |
| `PropertySpec.hs` | QuickCheck properties over conversions and DLQ payloads. |
| `IntegrationSpec.hs` | End-to-end behavior against a real ephemeral PostgreSQL. |
| `ChaosSpec.hs` | Adverse conditions: poison messages, slow handlers, graceful shutdown, and concurrent prefetch (deadlock-free drain, no-data-loss, bounded shutdown strand). |

Run them:

```bash
just test            # = cabal test shibuya-pgmq-adapter-test
# skip the DB-backed specs (unit/property only):
PGMQ_TEST_SKIP_DB=1 just test
```

## Current behavior references

For the behavior these tests assert, see:

- [`CONFIGURATION.md`](CONFIGURATION.md) — configuration surface and validation.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — message flow, ack semantics, shutdown.
- [`INTERNALS.md`](INTERNALS.md) — module-level implementation details.
