---
title: "Consume a pgmq queue through Shibuya"
type: Capability
description: "Turn a PostgreSQL pgmq queue into a Shibuya adapter with visibility-timeout leasing, the four ack decisions, auto-dead-lettering, lease extension, validated config, and loss-free graceful shutdown."
generated:
  by: claude-code/1.0
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-1
provider: mori://shinzui/shibuya-pgmq-adapter
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-pgmq-adapter
interface:
  - Shibuya.Adapter.Pgmq
  - Shibuya.Adapter.Pgmq.Config
evidence:
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs
    proves: End-to-end runs of pgmqAdapter under runApp against a real PostgreSQL (tmp-postgres) exercise poison-message handling, lease extension for long handlers, auto-dead-lettering, and graceful shutdown that drains an idle queue and stops accepting new work.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/IntegrationSpec.hs
    proves: Send/read/delete and visibility-timeout redelivery against a real PostgreSQL, via the direct effectful API.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConfigSpec.hs
    proves: defaultConfig values and validateConfig accept/reject rules (batch size, visibility timeout, retry policy, halt visibility timeout).
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/InternalSpec.hs
    proves: Query construction, Int32 saturation on visibility offsets, and bounded transient poll retry (retries transient errors, does not retry permanent ones, stops after maxAttempts).
  - kind: guide
    resource: docs/user/pgmq-getting-started.md
    proves: A consumer-facing walkthrough of installing the schema and wiring the adapter into a Shibuya app.
---

# Consume a pgmq queue through Shibuya

This is what the repository provides at its core: a
[Shibuya](https://github.com/shinzui/shibuya) `Adapter` backed by a
[pgmq](https://github.com/pgmq/pgmq) queue. A consumer builds the adapter from a
validated config and hands it to `runApp`; the adapter supplies the message
source and the framework drives the handler loop.

The adapter provides, in one adoption:

- **Visibility-timeout leasing.** Each read makes messages invisible for
  `visibilityTimeout` seconds; a message is never deleted on read, so an
  unacknowledged message is redelivered after the timeout (at-least-once).
- **The four ack decisions.** `AckOk` deletes, `AckRetry` extends the visibility
  timeout, `AckHalt` parks the message under `haltVisibilityTimeout`, and
  `AckDeadLetter` archives or routes it (see CAP-2, Dead-letter routing).
- **Automatic dead-lettering.** When pgmq's `readCount` exceeds `maxRetries`,
  the message is dead-lettered before it ever reaches the handler.
- **Lease extension.** Long-running handlers can push the visibility deadline
  forward; extension uses an absolute deadline so a later call never shortens
  the lease.
- **Typed config validation.** `validateConfig` rejects an invalid config as a
  typed `PgmqConfigError` before any stream starts.
- **Standard or long polling**, and **bounded transient retry** on both poll and
  ack paths (default: five attempts, 100 ms initial backoff, 5 s cap).
- **Loss-free graceful shutdown.** On shutdown the source releases just-read,
  undispatched messages so an idle processor stops promptly.

## Shortest usage

```haskell
Right adapter <- pgmqAdapter (mkPgmqAdapterEnv pool) (defaultConfig queueName)
runApp defaultAppConfig
  [ (ProcessorId "orders", QueueProcessor adapter handleOrder) ]
```

## Limits

- **At-least-once, not exactly-once.** A read only sets a visibility timeout;
  a crash between handler success and `AckOk` causes redelivery. Handlers must
  be idempotent.
- **`maxRetries` counts deliveries, not handler failures.** It is derived from
  pgmq's `readCount`, so a message read and abandoned (e.g. a crash before ack)
  counts against the budget. `maxRetries = 0` auto-dead-letters every message
  before processing.
- **The streaming path is proven by the chaos suite, not the integration
  suite.** `IntegrationSpec` marks its `pgmqAdapter` streaming cases pending
  (a documented Streamly/Effectful interaction) and covers only the direct
  effectful API; the end-to-end streaming guarantees above are the ones exercised
  in `ChaosSpec`.
- **Database-backed tests require PostgreSQL.** All integration and chaos
  evidence is skipped when `PGMQ_TEST_SKIP_DB=1`, so it only holds where the
  suite is run against a live server.
