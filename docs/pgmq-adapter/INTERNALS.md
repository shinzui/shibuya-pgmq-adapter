# PGMQ Adapter Internals

This document provides detailed implementation information for developers auditing or extending the shibuya-pgmq-adapter code.

## Table of Contents

- [Module Overview](#module-overview)
- [Public API (Pgmq.hs)](#public-api-pgmqhs)
- [Configuration (Config.hs)](#configuration-confighs)
- [Type Conversions (Convert.hs)](#type-conversions-converths)
- [Stream Implementation (Internal.hs)](#stream-implementation-internalhs)
- [pgmq-effectful Integration](#pgmq-effectful-integration)
- [Error Handling](#error-handling)
- [Thread Safety](#thread-safety)
- [Performance Considerations](#performance-considerations)
- [Test Coverage](#test-coverage)

## Module Overview

```
Shibuya.Adapter.Pgmq (Public API)
       │
       ├─► Shibuya.Adapter.Pgmq.Config (Configuration types)
       │
       ├─► Shibuya.Adapter.Pgmq.Convert (Type conversions)
       │
       └─► Shibuya.Adapter.Pgmq.Internal (Stream + ack implementation)
                     │
                     └─► Uses: pgmq-effectful, streamly, shibuya-core
```

### Dependency Flow

```haskell
-- Config.hs: No internal dependencies
import Pgmq.Types (QueueName)

-- Convert.hs: No internal dependencies
import Pgmq.Types qualified as Pgmq
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))

-- Internal.hs: Depends on Config and Convert
import Shibuya.Adapter.Pgmq.Config
import Shibuya.Adapter.Pgmq.Convert

-- Pgmq.hs: Depends on Config and Internal
import Shibuya.Adapter.Pgmq.Config
import Shibuya.Adapter.Pgmq.Internal
```

## Public API (Pgmq.hs)

**Location**: `src/Shibuya/Adapter/Pgmq.hs`

### pgmqAdapter

```haskell
pgmqAdapter ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) =>
  PgmqAdapterEnv ->
  PgmqAdapterConfig ->
  Eff es (Either PgmqConfigError (Adapter es Value))
```

**Implementation details**:

1. Validates configuration
2. Creates a shutdown TVar for graceful termination
3. Builds a chunk-aware source that can release just-read messages on shutdown
4. Returns an Adapter record on success

```haskell
pgmqAdapter env config =
  case validateConfig config of
    Left err -> pure (Left err)
    Right validConfig -> do
      shutdownVar <- liftIO $ newTVarIO False
      pure $
        Right
          Adapter
            { adapterName = "pgmq:" <> queueNameToText validConfig.queueName,
              source = pgmqSourceWithShutdown env validConfig shutdownVar,
              shutdown = liftIO $ atomically $ writeTVar shutdownVar True
            }
```

### pgmqSourceWithShutdown

The shutdown gate operates at chunk granularity, so a shutdown can release
messages that were read from pgmq but not yet handed to Shibuya's bounded inbox:

```haskell
pgmqSourceWithShutdown env config shutdownVar =
  chunkStream
    & Stream.filter (not . Vector.null)
    & Stream.takeWhileM keepChunk
    & Stream.unfoldEach (Unfold.unfoldr Vector.uncons)
    & Stream.mapMaybeM (mkIngested env config)
  where
    chunkStream = case config.prefetchConfig of
      Nothing -> pgmqChunks config
      Just prefetch ->
        pgmqChunksPrefetch (StreamP.maxBuffer (fromIntegral prefetch.bufferSize)) config
    keepChunk chunk = do
      isShutdown <- liftIO $ readTVarIO shutdownVar
      if isShutdown
        then do
          releaseMessages env config chunk
          pure False
        else pure True
```

**Behavior**: `keepChunk` reads the shutdown `TVar` once per chunk. When it is
set, it calls `releaseMessages env config chunk` — a best-effort batch release
that resets the just-read messages' visibility timeout to `0` via
`batchChangeVisibilityTimeout` (`set_vt 0`) so they are immediately redeliverable
— and then ends the stream by returning `False`.

**Note**: Uses `takeWhileM` not `takeWhile` because the predicate runs in
`Eff es`. `chunkStream` is `pgmqChunks config` in the default (non-prefetch)
path, and `pgmqChunksPrefetch ... config` when `prefetchConfig` is set.

## Configuration (Config.hs)

**Location**: `src/Shibuya/Adapter/Pgmq/Config.hs`

All configuration types are pure data with `Generic` deriving:

```haskell
data PgmqAdapterConfig = PgmqAdapterConfig { ... }
  deriving stock (Show, Eq, Generic)

data PollingConfig = StandardPolling { ... } | LongPolling { ... }
  deriving stock (Show, Eq, Generic)

data DeadLetterConfig = DeadLetterConfig { ... }
  deriving stock (Show, Eq, Generic)

data FifoConfig = FifoConfig { ... }
  deriving stock (Show, Eq, Generic)

data FifoReadStrategy = ThroughputOptimized | RoundRobin
  deriving stock (Show, Eq, Generic)
```

### Type Choices

| Field | Type | Rationale |
|-------|------|-----------|
| `visibilityTimeout` | `Int32` | Matches pgmq SQL parameter type |
| `batchSize` | `Int32` | Matches pgmq SQL parameter type |
| `maxRetries` | `Int64` | Matches pgmq `readCount` type |
| `pollInterval` | `NominalDiffTime` | Standard Haskell time difference |
| `bufferSize` | `Natural` | Non-negative, arbitrary precision |

## Type Conversions (Convert.hs)

**Location**: `src/Shibuya/Adapter/Pgmq/Convert.hs`

### messageIdToShibuya

```haskell
messageIdToShibuya :: Pgmq.MessageId -> MessageId
messageIdToShibuya (Pgmq.MessageId i) = MessageId (Text.pack (show i))
```

Converts Int64 to Text. Lossless for all Int64 values.

### messageIdToPgmq

```haskell
messageIdToPgmq :: MessageId -> Maybe Pgmq.MessageId
messageIdToPgmq (MessageId t) = Pgmq.MessageId <$> readMaybe (Text.unpack t)
  where
    readMaybe :: String -> Maybe Int64
    readMaybe s = case reads s of
      [(x, "")] -> Just x  -- Must consume entire string
      _ -> Nothing
```

Uses `reads` with empty-string check to ensure complete parse. Returns `Nothing` for:
- Non-numeric text
- Overflow values
- Trailing characters

### pgmqMessageIdToCursor

```haskell
pgmqMessageIdToCursor :: Pgmq.MessageId -> Cursor
pgmqMessageIdToCursor (Pgmq.MessageId i) = CursorInt (fromIntegral i)
```

Uses `CursorInt` variant since pgmq message IDs are sequential integers.

### extractPartition

```haskell
extractPartition :: Maybe Value -> Maybe Text
extractPartition headers = do
  Object obj <- headers      -- Pattern match on Object
  value <- KeyMap.lookup (Key.fromText "x-pgmq-group") obj
  case value of
    String group -> Just group
    _ -> Nothing             -- Non-string values ignored
```

FIFO partition comes from the `x-pgmq-group` header. Returns `Nothing` if:
- Headers are `Nothing`
- Headers are not a JSON Object
- Key is missing
- Value is not a String

### pgmqMessageToEnvelope

```haskell
pgmqMessageToEnvelope :: Pgmq.Message -> Envelope Value
pgmqMessageToEnvelope msg =
  Envelope
    { messageId = messageIdToShibuya msg.messageId,
      cursor = Just (pgmqMessageIdToCursor msg.messageId),
      partition = extractPartition msg.headers,
      enqueuedAt = Just msg.enqueuedAt,
      traceContext = extractTraceHeaders msg.headers,
      headers = Nothing,
      attempt = Just (readCountToAttempt msg.readCount),
      attributes = HashMap.empty,
      payload = Pgmq.unMessageBody msg.body
    }
```

The envelope has nine fields. `messageId`, `cursor` (`Just`), `partition`,
`enqueuedAt` (`Just`), `traceContext` (from `extractTraceHeaders`), `attempt`
(`Just (readCountToAttempt msg.readCount)`), and `payload` (the raw JSON `Value`
from pgmq) are populated. `headers` is deliberately `Nothing` — the JSONB
`headers` object is unordered user metadata consumed only to derive `partition`
and `traceContext`, not re-presented as broker headers — and `attributes` is
`HashMap.empty` (a forward-compatible hook; pgmq has no spec-defined typed
messaging attributes yet).

### mkDlqPayload

```haskell
mkDlqPayload :: Pgmq.Message -> DeadLetterReason -> Bool -> Pgmq.MessageBody
mkDlqPayload msg reason includeMetadata =
  Pgmq.MessageBody $
    object $
      [ "original_message" .= Pgmq.unMessageBody msg.body,
        "dead_letter_reason" .= reasonToText reason
      ]
        ++ metadataFields
  where
    metadataFields
      | includeMetadata =
          [ "original_message_id" .= Pgmq.unMessageId msg.messageId,
            "original_enqueued_at" .= msg.enqueuedAt,
            "last_read_at" .= msg.lastReadAt,
            "read_count" .= msg.readCount,
            "original_headers" .= msg.headers
          ]
      | otherwise = []

    reasonToText :: DeadLetterReason -> Text
    reasonToText = \case
      PoisonPill t -> "poison_pill: " <> t
      InvalidPayload t -> "invalid_payload: " <> t
      MaxRetriesExceeded -> "max_retries_exceeded"
```

Constructs JSON object for DLQ. Metadata fields are conditionally included.

## Stream Implementation (Internal.hs)

**Location**: `src/Shibuya/Adapter/Pgmq/Internal.hs`

### Query Constructors

Four functions create pgmq query types:

```haskell
mkReadMessage :: PgmqAdapterConfig -> ReadMessage
mkReadMessage config =
  ReadMessage
    { queueName = config.queueName,
      delay = config.visibilityTimeout,  -- VT in seconds
      batchSize = Just config.batchSize,
      conditional = Nothing              -- No conditional reads
    }

mkReadWithPoll :: PgmqAdapterConfig -> Int32 -> Int32 -> ReadWithPollMessage
mkReadWithPoll config maxSec intervalMs =
  ReadWithPollMessage
    { queueName = config.queueName,
      delay = config.visibilityTimeout,
      batchSize = Just config.batchSize,
      maxPollSeconds = maxSec,
      pollIntervalMs = intervalMs,
      conditional = Nothing
    }

mkReadGrouped :: PgmqAdapterConfig -> ReadGrouped
mkReadGrouped config =
  ReadGrouped
    { queueName = config.queueName,
      visibilityTimeout = config.visibilityTimeout,
      qty = config.batchSize
    }

mkReadGroupedWithPoll :: PgmqAdapterConfig -> Int32 -> Int32 -> ReadGroupedWithPoll
mkReadGroupedWithPoll config maxSec intervalMs =
  ReadGroupedWithPoll
    { queueName = config.queueName,
      visibilityTimeout = config.visibilityTimeout,
      qty = config.batchSize,
      maxPollSeconds = maxSec,
      pollIntervalMs = intervalMs
    }
```

### pgmqChunks

The core polling loop:

```haskell
pgmqChunks ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) (Vector Pgmq.Message)
pgmqChunks config = Stream.repeatM (retryingTransient config.pollRetry poll)
```

Each poll is wrapped in `retryingTransient config.pollRetry`, so a transient
`PgmqRuntimeError` is retried with bounded exponential backoff instead of tearing
down the stream. The `poll` function handles all four mode combinations:

```haskell
poll :: Eff es (Vector Pgmq.Message)
poll = case config.fifoConfig of
  Nothing -> pollNonFifo
  Just fifo -> pollFifo fifo

pollNonFifo = case config.polling of
  StandardPolling interval -> do
    result <- readMessage (mkReadMessage config)
    when (Vector.null result) $
      liftIO $ threadDelay (nominalToMicros interval)
    pure result
  LongPolling maxSec intervalMs ->
    readWithPoll (mkReadWithPoll config maxSec intervalMs)

pollFifo fifo = case config.polling of
  StandardPolling interval -> do
    result <- case fifo.readStrategy of
      ThroughputOptimized -> readGrouped (mkReadGrouped config)
      RoundRobin -> readGroupedRoundRobin (mkReadGrouped config)
    when (Vector.null result) $
      liftIO $ threadDelay (nominalToMicros interval)
    pure result
  LongPolling maxSec intervalMs ->
    case fifo.readStrategy of
      ThroughputOptimized ->
        readGroupedWithPoll (mkReadGroupedWithPoll config maxSec intervalMs)
      RoundRobin ->
        readGroupedRoundRobinWithPoll (mkReadGroupedWithPoll config maxSec intervalMs)
```

### pgmqChunksPrefetch

When `prefetchConfig` is set, `pgmqSourceWithShutdown` swaps `pgmqChunks` for
`pgmqChunksPrefetch`, which wraps the poll loop in Streamly's `parBuffered` so
batches are read on a background worker:

```haskell
pgmqChunksPrefetch prefetchSettings config =
  pgmqChunks config
    & StreamP.parBuffered prefetchSettings
    & Stream.morphInner (withUnliftStrategy (ConcUnlift Ephemeral Unlimited))
```

`parBuffered` forks worker threads that must unlift `Eff` to `IO`. effectful's
default `SeqUnlift` throws when its unlift runs off-thread (the historical
prefetch deadlock), so the concurrent stage is wrapped — via `morphInner`, so the
override is in force at the moment `parBuffered` forks — in a locally-scoped
`ConcUnlift` strategy. Because the scope is local to this stage, the non-prefetch
source path continues to run under `SeqUnlift` unchanged.

### Batch Flattening

```haskell
pgmqMessages ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) Pgmq.Message
pgmqMessages config =
  pgmqChunks config
    & Stream.filter (not . Vector.null)  -- Skip empty batches
    & Stream.unfoldEach vectorUnfold     -- Expand Vector to stream
  where
    vectorUnfold = Unfold.unfoldr Vector.uncons
```

**Key implementation detail**: `Stream.unfoldEach vectorUnfold` is critical for correct behavior.

`vectorUnfold` uses `Unfold.unfoldr Vector.uncons`:
- `Vector.uncons :: Vector a -> Maybe (a, Vector a)`
- Returns `Just (head, tail)` or `Nothing` when empty
- `Unfold.unfoldr` creates an `Unfold` from this step function

This ensures every element in every batch is yielded to the stream.

### mkIngested

```haskell
mkIngested ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) =>
  PgmqAdapterEnv ->
  PgmqAdapterConfig ->
  Pgmq.Message ->
  Eff es (Maybe (Ingested es Value))
mkIngested env config msg = do
  finalizedRef <- liftIO $ newIORef False
  lease <- mkLease config msg
  let ackHandle = mkAckHandle env config finalizedRef msg
  if msg.readCount > config.maxRetries
    then do
      -- Auto dead-letter messages that exceed the retry limit
      finalizeAutoDeadLetter
        msg
        env.onAutoDeadLetter
        env.onAckFailure
        (ackHandle.finalize (AckDeadLetter MaxRetriesExceeded))
      pure Nothing  -- Filter from stream
    else
      pure $ Just Ingested
        { envelope = pgmqMessageToEnvelope msg,
          ack = ackHandle,
          lease = Just lease
        }
```

`mkIngested` allocates the shared `finalizedRef :: IORef Bool` (the ack
idempotency guard), binds the lease via the effectful `mkLease config msg`, and
builds the `AckHandle` with `mkAckHandle env config finalizedRef msg`.

**Auto-DLQ logic**:
1. Compare `readCount` to `maxRetries` (using `>`, not `>=`)
2. If exceeded, run the finalize via `finalizeAutoDeadLetter`, which invokes
   `ackHandle.finalize (AckDeadLetter MaxRetriesExceeded)` and then calls the
   `env.onAutoDeadLetter` callback on success or routes a permanent failure to
   `env.onAckFailure`
3. Return `Nothing` to filter the message from the stream

This means a message with `maxRetries = 3` is dead-lettered on the 4th read.

### mkAckHandle

```haskell
mkAckHandle ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) =>
  PgmqAdapterEnv ->
  PgmqAdapterConfig ->
  IORef Bool ->
  Pgmq.Message ->
  AckHandle es
mkAckHandle env config finalizedRef msg = AckHandle $ \decision -> do
  alreadyFinalized <- liftIO $ readIORef finalizedRef
  if alreadyFinalized
    then pure ()
    else do
      runDecision decision
      liftIO $ writeIORef finalizedRef True
  where
    queueName = config.queueName
    msgId = msg.messageId

    runDecision decision = retryingTransient config.ackRetry $ case decision of
      AckOk ->
        void $ deleteMessage (MessageQuery queueName msgId)

      AckRetry (RetryDelay delay) -> do
        let vtSeconds = nominalToSeconds delay
        void $ changeVisibilityTimeout $ VisibilityTimeoutQuery
          { queueName = queueName,
            messageId = msgId,
            visibilityTimeoutOffset = vtSeconds
          }

      AckDeadLetter reason ->
        case config.deadLetterConfig of
          Nothing ->
            void $ archiveMessage (MessageQuery queueName msgId)
          Just dlqConfig -> do
            consumerHdrs <- currentTraceHeaders
            deadLetterTransactionally env config dlqConfig msg reason
              (mergeDlqHeaders consumerHdrs msg.headers)

      AckHalt _reason -> do
        let vtSeconds = maybe config.visibilityTimeout id config.haltVisibilityTimeout
        void $ changeVisibilityTimeout $ VisibilityTimeoutQuery
          { queueName = queueName,
            messageId = msgId,
            visibilityTimeoutOffset = vtSeconds
          }
```

**Idempotency guard**: The shared `finalizedRef :: IORef Bool` (allocated by
`mkIngested`) makes finalization a no-op once a decision has already succeeded —
a second call to `finalize` on the same handle does nothing. The whole decision
is wrapped in `retryingTransient config.ackRetry`, so transient errors are
retried with bounded exponential backoff.

**Decision handling**:

- `AckOk` → `deleteMessage`.
- `AckRetry (RetryDelay d)` → `changeVisibilityTimeout` with offset
  `nominalToSeconds d`.
- `AckDeadLetter` with a configured DLQ → `deadLetterTransactionally`, a single
  hasql `ReadCommitted`/`Write` transaction that atomically sends the message to
  the DLQ target and deletes it from the source queue. It merges the consumer's
  current trace headers via `mergeDlqHeaders consumerHdrs msg.headers`. Without a
  configured DLQ, the branch falls back to `archiveMessage`.
- `AckHalt` → `changeVisibilityTimeout` with offset
  `maybe config.visibilityTimeout id config.haltVisibilityTimeout` (i.e. the
  configured halt VT, or the ordinary visibility timeout — not a hardcoded
  `3600`).

The DLQ target comes from `dlqConfig.dlqTarget :: DeadLetterTarget`, where
`DeadLetterTarget = DirectQueue !QueueName | TopicRoute !RoutingKey`. There is no
`dlqQueueName` field. `void` is imported from `Control.Monad`.

### mkLease

```haskell
mkLease ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Pgmq.Message ->
  Eff es (Lease es)
mkLease config msg = do
  lastVtRef <- liftIO $ newIORef msg.visibilityTime
  pure Lease
    { leaseId = Text.pack (show (Pgmq.unMessageId msg.messageId)),
      leaseExtend = \duration -> do
        now <- liftIO getCurrentTime
        lastVt <- liftIO $ readIORef lastVtRef
        let target = max lastVt (addUTCTime duration now)
        updated <-
          retryingTransient config.ackRetry $
            setVisibilityTimeoutAt $ VisibilityTimeoutAtQuery
              { queueName = config.queueName,
                messageId = msg.messageId,
                visibilityTime = target
              }
        liftIO $ writeIORef lastVtRef updated.visibilityTime
    }
```

`mkLease` is now effectful: it allocates an `IORef` (`lastVtRef`) seeded from
`msg.visibilityTime`. `leaseExtend duration` computes
`target = max lastVt (addUTCTime duration now)` and calls `setVisibilityTimeoutAt`
with an **absolute** timestamp (rather than the offset-based
`changeVisibilityTimeout`), so the timeout is monotone and never shortened by a
later, shorter extension. The call is wrapped in `retryingTransient
config.ackRetry`, and the returned VT is written back to `lastVtRef`. Handlers
call `leaseExtend` to extend the visibility timeout for long-running work.

### nominalToSeconds

```haskell
nominalToSeconds :: NominalDiffTime -> Int32
nominalToSeconds dt =
  let seconds = realToFrac (nominalDiffTimeToSeconds dt) :: Double
      maxSec = fromIntegral (maxBound :: Int32)
      minSec = fromIntegral (minBound :: Int32)
      clamped = max minSec (min maxSec seconds)
   in ceiling clamped
```

Converts to seconds and rounds up (`ceiling`), but **saturates** at the `Int32`
bounds instead of wrapping. A 1.1 second delay becomes 2 seconds; a delay larger
than `maxBound :: Int32` (~68 years) is clamped to `maxBound` rather than silently
overflowing, so a misconfigured `maxDelay` yields a merely-very-long retry rather
than a corrupt one.

## pgmq-effectful Integration

The adapter uses these pgmq-effectful functions:

| Function | Purpose | Used by |
|----------|---------|---------|
| `readMessage` | Read messages (standard) | `pollNonFifo` |
| `readWithPoll` | Read with database blocking | `pollNonFifo` |
| `readGrouped` | FIFO read (throughput) | `pollFifo` |
| `readGroupedRoundRobin` | FIFO read (round-robin) | `pollFifo` |
| `readGroupedWithPoll` | FIFO + long poll (throughput) | `pollFifo` |
| `readGroupedRoundRobinWithPoll` | FIFO + long poll (round-robin) | `pollFifo` |
| `deleteMessage` | Delete processed message | `mkAckHandle` (AckOk); DLQ transaction |
| `archiveMessage` | Archive without DLQ | `mkAckHandle` (DLQ fallback) |
| `changeVisibilityTimeout` | Extend VT by offset | `mkAckHandle` (AckRetry, AckHalt) |
| `setVisibilityTimeoutAt` | Set VT to absolute timestamp | `mkLease` (`leaseExtend`) |
| `batchChangeVisibilityTimeout` | Batch-release read messages (`set_vt 0`) | `releaseMessages` (shutdown) |
| `sendMessage` / `sendMessageWithHeaders` | Send to DLQ direct queue | `deadLetterTransactionally` (DirectQueue) |
| `sendTopic` / `sendTopicWithHeaders` | Route to DLQ topic | `deadLetterTransactionally` (TopicRoute) |

The DLQ send path does not go through the `Pgmq` effect's high-level send: it runs
the `sendMessage`/`sendMessageWithHeaders`/`sendTopic`/`sendTopicWithHeaders` hasql
statements directly inside a single `ReadCommitted`/`Write` transaction (via
`Hasql.Pool.use env.pool`) so the DLQ write and the source delete commit
atomically. `mkLease` uses `setVisibilityTimeoutAt` (absolute), not
`changeVisibilityTimeout`.

## Error Handling

### Effect-Based Errors

pgmq operations surface failures as `PgmqRuntimeError` through the effect system.
The adapter no longer lets every error propagate unhandled: both the poll path
(`pgmqChunks`) and the ack paths (`mkAckHandle`, `mkLease`, `releaseMessages`)
wrap their operations in `retryingTransient`, which retries transient errors
(those for which `isTransient` holds) with bounded exponential backoff
(`pollRetry` / `ackRetry`). A non-transient error, or one that exhausts the retry
budget, is re-thrown; on the poll path it propagates to the Shibuya supervisor for
restart, while swallowed ack and auto-DLQ failures are routed to the
`env.onAckFailure` / `env.onAutoDeadLetter` callbacks instead of tearing down the
stream.

### Auto-DLQ as Defensive Programming

Messages that exceed `maxRetries` are automatically dead-lettered in `mkIngested`. This prevents:
- Infinite retry loops
- Poison pills blocking the queue
- Handler having to track retry counts

## Thread Safety

### TVar for Shutdown

The shutdown mechanism uses `TVar Bool` with STM:

```haskell
shutdownVar <- newTVarIO False
-- ...
shutdown = liftIO $ atomically $ writeTVar shutdownVar True
-- ...
Stream.takeWhileM keepChunk  -- keepChunk reads the TVar once per chunk
```

STM ensures atomic reads/writes. No race conditions between the shutdown signal
and stream consumption.

The gate is **chunk-level**, not per-element: `keepChunk` (driven by
`Stream.takeWhileM`) reads the shutdown `TVar` once per polled batch. When it
observes shutdown, it additionally calls `releaseMessages env config chunk` to
reset the visibility timeout of the just-read, undispatched messages so they are
redeliverable immediately rather than after the visibility timeout expires, then
ends the stream.

## Performance Considerations

### Batch Efficiency

After the optimization, all messages in each batch are processed:

| Batch Size | Messages per Poll | DB Roundtrips per N Messages |
|------------|-------------------|------------------------------|
| 1 | 1 | N |
| 10 | 10 | N/10 |
| 100 | 100 | N/100 |

### Memory Usage

Memory usage scales with:
- `batchSize` - size of each Vector
- Shibuya inbox size - messages waiting for handler

Worst-case adapter/core buffered messages are bounded by the current pgmq chunk plus Shibuya's inbox size.

### CPU Overhead

Main sources of CPU usage:
1. JSON parsing (handled by aeson)
2. Stream transformations (Streamly optimized)
3. TVar reads for shutdown check (cheap)

## Test Coverage

The HSpec suite lives under `test/Shibuya/Adapter/Pgmq/` and comprises
`ConvertSpec`, `ConfigSpec`, `InternalSpec`, `PropertySpec`, `IntegrationSpec`,
and `ChaosSpec`. `IntegrationSpec` and `ChaosSpec` run against a live PostgreSQL
instance spun up ephemerally via `TmpPostgres` (`test/TmpPostgres.hs`), so the
integration and fault-injection paths exercise real pgmq behavior.

### Property Tests

| Test | Property |
|------|----------|
| `messageIdToShibuya/messageIdToPgmq` | Roundtrip for all Int64 |
| `pgmqMessageIdToCursor` | Correct CursorInt value |

### Unit Tests

| Test | Coverage |
|------|----------|
| Envelope construction | All fields populated correctly |
| Partition extraction | Handles missing/malformed headers |
| DLQ payload with metadata | All metadata fields present |
| DLQ payload without metadata | Only required fields |
| Reason text conversion | All DeadLetterReason variants |

### Integration Tests

`IntegrationSpec` and `ChaosSpec` run end-to-end against an ephemeral PostgreSQL
instance (started via `TmpPostgres`). The pgmq schema is installed without the
extension: `TmpPostgres` composes `pgmq-migration`'s `pg-migrate` component into a
plan and runs it against the fresh database. Coverage:

1. End-to-end message processing
2. Visibility timeout behavior
3. DLQ flow
4. FIFO ordering verification
5. Graceful shutdown with in-flight messages, including release of read-but-undispatched messages
6. Transient-error retry and fault injection (`ChaosSpec`)
