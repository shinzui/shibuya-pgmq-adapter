# PGMQ Adapter for Shibuya

The `shibuya-pgmq-adapter` package provides integration between Shibuya and [pgmq](https://github.com/tembo-io/pgmq) (PostgreSQL Message Queue). This adapter enables Shibuya to consume messages from PostgreSQL-backed queues with visibility timeout semantics, automatic retry handling, and optional dead-letter queue support.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Features](#features)
- [Requirements](#requirements)
- [Module Structure](#module-structure)
- [Related Documentation](#related-documentation)

## Overview

The pgmq adapter creates a Shibuya `Adapter` that:

1. **Polls messages** from a pgmq queue with configurable polling strategies
2. **Manages visibility timeouts** to prevent duplicate processing
3. **Maps Shibuya ack decisions** to appropriate pgmq operations
4. **Provides lease extension** for long-running handlers
5. **Handles automatic dead-lettering** when retry limits are exceeded
6. **Supports FIFO ordering** via pgmq's grouped read operations

```
┌─────────────────────────────────────────────────────────────────┐
│                     Shibuya Application                          │
│                                                                   │
│  runApp → Master → Processor                                      │
│                        │                                          │
│              ┌─────────┴─────────┐                                │
│              │  pgmqAdapter      │                                │
│              │                   │                                │
│              │  source (stream)──┼──► Ingested messages           │
│              │  shutdown         │                                │
│              └───────────────────┘                                │
│                        │                                          │
└────────────────────────┼──────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                  pgmq-effectful / PostgreSQL                     │
│                                                                   │
│  • readMessage / readWithPoll                                     │
│  • readGrouped / readGroupedRoundRobin                           │
│  • deleteMessage / archiveMessage                                 │
│  • changeVisibilityTimeout / sendMessage                          │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Installation

Add to your `.cabal` file:

```cabal
build-depends:
  shibuya-core,
  shibuya-pgmq-adapter,
  pgmq-effectful,
  hasql-pool,
```

### Basic Usage

```haskell
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp)
import Shibuya.Adapter.Pgmq
import Pgmq.Effectful (runPgmq)
import Hasql.Pool qualified as Pool
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Shibuya.Telemetry.Effect (runTracing)
import OpenTelemetry.Trace qualified as OTel

main :: IO ()
main = do
  -- Create PostgreSQL connection pool
  pool <- Pool.acquire poolSettings

  -- Parse queue name (validated)
  let Right queueName = parseQueueName "orders"

  -- Create adapter configuration
  let config = defaultConfig queueName

  -- Set up an OpenTelemetry tracer. `pgmqAdapter` requires `Tracing :> es`,
  -- so the effect stack must include a tracing interpreter. The example app
  -- (shibuya-pgmq-example) wires a real tracer the same way via `runTracing`.
  provider <- OTel.initializeGlobalTracerProvider
  let tracer = OTel.makeTracer provider "shibuya" OTel.tracerOptions

  -- Run with effectful
  runResult <- runEff $ runErrorNoCallStack $ runPgmq pool $ runTracing tracer $ do
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
        -- Application is running...
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

### With Dead-Letter Queue

```haskell
let config = (defaultConfig queueName)
      { deadLetterConfig = Just $ directDeadLetter dlqName True,
        maxRetries = 3
      }
```

### With Topic-Routed Dead-Letter (pgmq 1.11.0+)

```haskell
let Right routingKey = parseRoutingKey "dlq.orders.failed"
let config = (defaultConfig queueName)
      { deadLetterConfig = Just $ topicDeadLetter routingKey True,
        maxRetries = 3
      }
```

### With FIFO Ordering

```haskell
let config = (defaultConfig queueName)
      { fifoConfig = Just FifoConfig
          { readStrategy = RoundRobin
          }
      }
```

### With Concurrent Prefetch (opt-in)

Prefetch reads the next batches on a background worker while the current
messages are processed, overlapping database latency with handler work.

```haskell
let config = (defaultConfig queueName)
      { prefetchConfig = Just defaultPrefetchConfig  -- buffers 4 batches ahead
      }
```

Trade-offs:

- Prefetched messages have their visibility timeout ticking while buffered, so
  keep `bufferSize * batchSize * avgProcessingTime < visibilityTimeout`.
- **Shutdown (no data loss).** A shutdown can leave up to `bufferSize * batchSize`
  already-read messages invisible until their visibility timeout expires. No
  messages are lost — pgmq redelivers them once the VT elapses; only redelivery
  is delayed. This bounded, at-least-once-safe edge case is inherent to reading
  ahead. Leave `prefetchConfig = Nothing` (the default) if prompt shutdown
  release matters more than polling latency.

## Features

| Feature | Description |
|---------|-------------|
| **Batch Polling** | Configurable batch sizes for efficient database access |
| **Long Polling** | Database-side blocking to reduce empty poll overhead |
| **Visibility Timeout** | Messages become invisible during processing |
| **Lease Extension** | Handlers can extend timeout for long-running operations |
| **Automatic Retry** | Uses pgmq's `readCount` to track and limit retries |
| **Dead-Letter Queue** | Optional DLQ with configurable metadata inclusion |
| **FIFO Ordering** | Grouped message processing with pgmq 1.8.0+ |
| **Concurrent Prefetch** | Opt-in read-ahead of batches under a scoped `ConcUnlift` strategy (no data loss on shutdown) |
| **Graceful Shutdown** | Stops polling while allowing in-flight messages to complete |

## Requirements

- **GHC 9.12+** (GHC2024 language standard)
- **PostgreSQL** with the pgmq schema installed, either as the extension or via `pgmq-migration`
- **pgmq 1.8.0+** for FIFO support
- **pgmq-\* 0.4** package family
- **effectful 2.6+** for effect system integration

Installing the schema with `pgmq-migration` 0.4 means composing its `pg-migrate` component into a
plan; a database created by `pgmq-migration` 0.3 or earlier must have its `hasql-migration` ledger
imported first. See [Installing the PGMQ
schema](../user/pgmq-getting-started.md#installing-the-pgmq-schema).

### Key Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `pgmq-core` | - | pgmq type definitions |
| `pgmq-effectful` | - | effectful integration for pgmq operations |
| `pgmq-hasql` | - | Hasql-based pgmq client |
| `shibuya-core` | - | Shibuya framework types |
| `streamly` | ^0.11 | Stream processing |
| `streamly-core` | ^0.3 | Streamly core utilities |
| `effectful-core` | ^2.6.1 | Effect system |

## Module Structure

```
shibuya-pgmq-adapter/
├── shibuya-pgmq-adapter.cabal
├── src/
│   └── Shibuya/
│       └── Adapter/
│           ├── Pgmq.hs              # Public API (pgmqAdapter, exports)
│           └── Pgmq/
│               ├── Config.hs        # Configuration types
│               ├── Convert.hs       # Type conversions (pgmq ↔ Shibuya)
│               └── Internal.hs      # Stream implementation (not public)
└── test/
    ├── Main.hs
    ├── TestUtils.hs                 # Shared test helpers
    ├── TmpPostgres.hs               # Ephemeral PostgreSQL (ephemeral-pg)
    └── Shibuya/
        └── Adapter/
            └── Pgmq/
                ├── ChaosSpec.hs        # Fault-injection / chaos tests
                ├── ConfigSpec.hs       # Configuration tests
                ├── ConvertSpec.hs      # Conversion tests
                ├── IntegrationSpec.hs  # End-to-end integration tests
                ├── InternalSpec.hs     # Stream/polling internals tests
                └── PropertySpec.hs     # Property-based tests
```

### Public Modules

| Module | Purpose |
|--------|---------|
| `Shibuya.Adapter.Pgmq` | Main entry point. Exports `pgmqAdapter` and all configuration types. |
| `Shibuya.Adapter.Pgmq.Config` | Configuration type definitions only. |
| `Shibuya.Adapter.Pgmq.Convert` | Type conversion utilities for advanced use cases. |

### Internal Modules

| Module | Purpose |
|--------|---------|
| `Shibuya.Adapter.Pgmq.Internal` | Stream construction, polling logic, ack handling. Not part of public API. |

## Related Documentation

- [User Guides](../user/README.md) - Task-oriented guides for common use cases
- [ARCHITECTURE.md](./ARCHITECTURE.md) - Data flow, design decisions, message lifecycle
- [CONFIGURATION.md](./CONFIGURATION.md) - Complete configuration reference
- [INTERNALS.md](./INTERNALS.md) - Implementation details for code auditing
- [Shibuya Core Architecture](../architecture/MESSAGE_FLOW.md) - How Shibuya processes messages
- [pgmq Documentation](https://tembo.io/pgmq/) - Upstream pgmq documentation
