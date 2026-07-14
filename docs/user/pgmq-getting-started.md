# PGMQ Adapter: Getting Started

This guide covers setting up the PGMQ adapter to consume messages from PostgreSQL-backed queues.

## Prerequisites

- PostgreSQL with the [pgmq](https://github.com/tembo-io/pgmq) schema available, either as the
  installed extension or installed by `pgmq-migration` (see [Installing the PGMQ
  schema](#installing-the-pgmq-schema))
- pgmq 1.8.0+ for FIFO support, pgmq 1.11.0+ for topic routing

## Installation

Add to your `.cabal` file:

```cabal
build-depends:
  shibuya-core,
  shibuya-pgmq-adapter,
  pgmq-effectful,
  hasql-pool,
```

The adapter requires the `pgmq-*` 0.4 package family.

## Installing the PGMQ schema

If your PostgreSQL cannot install the pgmq extension (managed instances often cannot), use
`pgmq-migration` to install the same schema as ordinary SQL.

As of `pgmq-migration` 0.4 this is a [`pg-migrate`](https://hackage.haskell.org/package/pg-migrate)
component rather than a self-contained runner. `pgmq-migration` no longer migrates anything on its
own: it *exports* the pgmq migrations, and your application composes them into a plan alongside its
own migrations and runs that plan. This is what lets one ledger own both pgmq's schema and yours.

```haskell
import Data.List.NonEmpty (NonEmpty ((:|)))
import Database.PostgreSQL.Migrate qualified as Migrate
import Hasql.Connection.Settings qualified as Settings
import Pgmq.Migration qualified as Migration

installPgmqSchema :: Settings.Settings -> IO ()
installPgmqSchema connSettings = do
  component <- either (fail . show) pure Migration.pgmqMigrations
  plan <- either (fail . show) pure (Migrate.migrationPlan (component :| []))
  result <- Migrate.runMigrationPlan Migrate.defaultRunOptions connSettings plan
  either (fail . show) (const (pure ())) result
```

Two things differ from a typical `hasql` call:

- The runner takes connection **settings**, not a `Pool` or `Connection` — it acquires its own
  connection so the migration advisory lock lives outside your application pool.
- Running an already-migrated database is a no-op, so this is safe to call on every boot.

To run pgmq's migrations together with your own, pass both components to `migrationPlan` in the
order you want them applied (`Migration.pgmqMigrations :| [myComponent]`).

### Upgrading a database created by pgmq-migration 0.3 or earlier

Skip this if your database is fresh — the plan above installs from scratch.

Earlier releases tracked migrations with `hasql-migration` in `public.schema_migrations`. The native
runner keeps its own ledger and **does not read that table**, so pointing it at an already-populated
database would try to reinstall the schema and fail. Import the old ledger first, once, using
`Pgmq.Migration.History.HasqlMigration`:

- **`DirectFullInstallHistory`** — for a database whose ledger records the `pgmq_v1.11.0`
  full install. The import verifies the recorded MD5 before adopting it.
- **`EquivalentTwoStepUpgradeHistory`** — for a database that stepped through
  `v1.10.0 -> v1.10.1 -> v1.11.0`. It is never selected implicitly: you opt in explicitly, and it is
  additionally guarded by a read-only PGMQ 1.11 schema contract (`Pgmq.Migration.SchemaContract`)
  that checks the live schema matches what pgmq-hs expects.

The import only rewrites migration bookkeeping; it does not execute the pgmq DDL again. Afterwards
the native runner takes over, and its first real upgrade (`0002-schema-management-comment`, a
non-destructive `COMMENT ON SCHEMA pgmq`) proves the handover worked.

For a disposable development database, dropping `schema_migrations` and the `pgmq` schema and
re-running the plan is simpler than importing.

## Basic Consumer

```haskell
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp)
import Shibuya.Adapter.Pgmq
import Pgmq.Effectful (runPgmq)
import Hasql.Pool qualified as Pool
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)

main :: IO ()
main = do
  -- Create PostgreSQL connection pool
  pool <- Pool.acquire poolSettings

  -- Parse queue name (validated)
  let Right queueName = parseQueueName "orders"

  -- Create adapter configuration
  let config = defaultConfig queueName

  -- Run with effectful
  runResult <- runEff $ runErrorNoCallStack $ runPgmq pool $ do
    let env = mkPgmqAdapterEnv pool

    -- Create adapter
    adapterResult <- pgmqAdapter env config
    adapter <- case adapterResult of
      Left err -> liftIO $ fail $ "Invalid PGMQ adapter config: " <> show err
      Right adapter -> pure adapter

    -- Start Shibuya application
    result <- runApp defaultAppConfig
      [ (ProcessorId "orders", mkProcessor adapter handleOrder)
      ]

    case result of
      Left err -> liftIO $ print err
      Right handle -> do
        liftIO waitForShutdown
        stopApp handle

  case runResult of
    Left err -> print err
    Right () -> pure ()

handleOrder :: Handler es Value
handleOrder ingested = do
  case parseOrder (ingested.envelope.payload) of
    Left err -> pure $ AckDeadLetter (InvalidPayload err)
    Right order -> do
      processOrder order
      pure AckOk
```

## Configuration Basics

The `defaultConfig` provides sensible defaults:

```haskell
defaultConfig :: QueueName -> PgmqAdapterConfig
-- visibilityTimeout = 30 seconds
-- batchSize = 1
-- polling = StandardPolling (1 second)
-- pollRetry = defaultPollRetryConfig
-- ackRetry = defaultPollRetryConfig
-- deadLetterConfig = Nothing
-- haltVisibilityTimeout = Nothing
-- maxRetries = 3
-- fifoConfig = Nothing
-- prefetchConfig = Nothing
```

Override fields as needed:

```haskell
let config = (defaultConfig queueName)
      { batchSize = 10,
        visibilityTimeout = 60,
        maxRetries = 5
      }
```

## Polling Strategies

### Standard Polling

Client-side sleep between polls when the queue is empty:

```haskell
let config = (defaultConfig queueName)
      { polling = StandardPolling { pollInterval = 0.5 }  -- 500ms
      }
```

Best when the queue usually has messages.

### Long Polling

Database-side blocking until messages arrive:

```haskell
let config = (defaultConfig queueName)
      { polling = LongPolling
          { maxPollSeconds = 10,
            pollIntervalMs = 100
          }
      }
```

Best when the queue is often empty. Reduces database round-trips but holds a connection during the wait.

## Multi-Queue Consumer

Set up multiple processors consuming from different queues:

```haskell
runConsumer pool = do
  runResult <- runEff $ runErrorNoCallStack $ runPgmq pool $ do
    let env = mkPgmqAdapterEnv pool
        requireAdapter result =
          case result of
            Left err -> liftIO $ fail $ "Invalid PGMQ adapter config: " <> show err
            Right adapter -> pure adapter

    ordersAdapter <- requireAdapter =<< pgmqAdapter env ordersConfig
    paymentsAdapter <- requireAdapter =<< pgmqAdapter env paymentsConfig
    notificationsAdapter <- requireAdapter =<< pgmqAdapter env notificationsConfig

    result <- runApp defaultAppConfig
      [ (ProcessorId "orders", mkProcessor ordersAdapter ordersHandler),
        (ProcessorId "payments", mkProcessor paymentsAdapter paymentsHandler),
        (ProcessorId "notifications", mkProcessor notificationsAdapter notificationsHandler)
      ]

    case result of
      Left err -> liftIO $ print err
      Right appHandle -> do
        liftIO $ putStrLn "All processors running"
        -- Wait for shutdown signal...
        let shutdownConfig = ShutdownConfig { drainTimeout = 30 }
        stopAppGracefully shutdownConfig appHandle

  case runResult of
    Left err -> print err
    Right () -> pure ()
```

## Message Lifecycle

1. Messages are read from pgmq with a visibility timeout
2. During processing, messages are invisible to other consumers
3. On `AckOk`, messages are deleted from the queue
4. On `AckRetry`, visibility timeout is extended by the retry delay
5. On `AckDeadLetter`, messages are archived or sent to DLQ
6. On `AckHalt`, visibility timeout is extended to `haltVisibilityTimeout` or `visibilityTimeout`, and the processor stops

## Automatic Retry Tracking

pgmq tracks retries via the `readCount` field. When a message's `readCount` exceeds `maxRetries`:

1. The adapter automatically dead-letters the message
2. The handler never sees the message
3. No manual retry tracking needed

## Next Steps

- [Dead-Letter Queues](./pgmq-dead-letter-queues.md) - Configure DLQ with direct or topic-based routing
- [Topic Routing](./pgmq-topic-routing.md) - AMQP-like topic binding and pattern matching
- [Advanced PGMQ](./pgmq-advanced.md) - FIFO ordering, lease extension, tuning
- [Configuration Reference](../pgmq-adapter/CONFIGURATION.md) - Complete field-by-field reference
