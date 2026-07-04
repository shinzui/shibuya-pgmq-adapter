# PGMQ Adapter Architecture

This document describes the architecture, data flow, and design decisions of the shibuya-pgmq-adapter.

## Table of Contents

- [Overview](#overview)
- [Message Lifecycle](#message-lifecycle)
- [Stream Architecture](#stream-architecture)
- [Type Mappings](#type-mappings)
- [Ack Decision Handling](#ack-decision-handling)
- [Polling Strategies](#polling-strategies)
- [FIFO Support](#fifo-support)
- [Shutdown Handling](#shutdown-handling)
- [Design Decisions](#design-decisions)

## Overview

The pgmq adapter bridges two systems:

1. **pgmq** - A PostgreSQL-based message queue with visibility timeout semantics
2. **Shibuya** - A supervised queue processing framework with explicit ack semantics

The adapter translates between these models:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           pgmqAdapter                                    │
│                                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                      Stream Pipeline                             │   │
│   │                                                                  │   │
│   │  pgmqChunks ──► unfoldEach ──► mkIngested ──► Ingested stream   │   │
│   │       │                             │                            │   │
│   │  [Poll pgmq]                  [Convert + filter]                 │   │
│   │  [Vector Message]             [auto-DLQ if maxRetries]           │   │
│   │                                                                  │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                │                                         │
│                                ▼                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                        Ingested                                  │   │
│   │                                                                  │   │
│   │   envelope ──► Envelope Value (message payload + metadata)       │   │
│   │   ack ──────► AckHandle (maps decisions to pgmq operations)     │   │
│   │   lease ────► Lease (extends visibility timeout)                 │   │
│   │                                                                  │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Message Lifecycle

### 1. Message Read from Queue

```
PostgreSQL (pgmq)              Adapter                    Shibuya
      │                          │                          │
      │  readMessage/Poll        │                          │
      │◄─────────────────────────│                          │
      │                          │                          │
      │  Vector Message          │                          │
      │─────────────────────────►│                          │
      │                          │                          │
      │  (VT started ticking)    │  unfoldEach + mkIngested │
      │                          │─────────────────────────►│
      │                          │  Ingested es Value       │
```

When a message is read:
- pgmq sets the message's visibility timeout (VT)
- The message is invisible to other consumers for the VT duration
- pgmq increments the message's `readCount`

### 2. Processing and Acking

```
Shibuya                          Adapter                    PostgreSQL
   │                               │                             │
   │  Handler processes message    │                             │
   │  ─────────────────────────►   │                             │
   │                               │                             │
   │  Returns AckDecision          │                             │
   │  ◄─────────────────────────   │                             │
   │                               │                             │
   │  ack.finalize(decision)       │                             │
   │  ─────────────────────────►   │                             │
   │                               │  deleteMessage (AckOk)      │
   │                               │ ─────────────────────────► │
   │                               │                             │
```

### 3. Visibility Timeout Expiry

If processing takes longer than VT without extending the lease:

```
Time ──────────────────────────────────────────────────►

 │                                                    │
 ├── Message read ──┬─── VT window ───┬── Visible ───┤
 │                  │                 │   again      │
 │                  │                 │              │
 │              Processing...     Timeout!        Other consumer
 │              (handler running)               can read message
```

## Stream Architecture

The adapter constructs a Streamly stream through several layers.

### Layer 1: Chunk Polling (`pgmqChunks` / `pgmqChunksPrefetch`)

```haskell
pgmqChunks :: Stream (Eff es) (Vector Pgmq.Message)
pgmqChunks config = Stream.repeatM (retryingTransient config.pollRetry poll)
```

- Infinite stream of message batches
- Each poll returns a `Vector Message`
- Handles both standard and long polling
- Handles both FIFO and non-FIFO modes
- Transient poll errors are retried per `config.pollRetry`

When `prefetchConfig` is enabled, `pgmqChunksPrefetch` wraps `pgmqChunks` in Streamly's `parBuffered` (scoped under `ConcUnlift`) so batches are polled ahead on a background worker. See "Concurrent Prefetch" below.

### Layer 2: Batch Flattening (`pgmqMessages`)

```haskell
pgmqMessages :: Stream (Eff es) Pgmq.Message
pgmqMessages config =
  pgmqChunks config
    & Stream.filter (not . Vector.null)
    & Stream.unfoldEach vectorUnfold
```

Key insight: Uses `unfoldEach` to expand each `Vector` into individual elements. This ensures **all messages from each batch are processed**, not just the first.

### Layer 3: Conversion (`pgmqSource`)

```haskell
pgmqSource :: PgmqAdapterEnv -> PgmqAdapterConfig -> Stream (Eff es) (Ingested es Value)
pgmqSource env config =
  pgmqMessages config
    & Stream.mapMaybeM (mkIngested env config)
```

- Converts each `Pgmq.Message` to `Ingested es Value`
- Filters out auto-dead-lettered messages (returns `Nothing`)
- Creates `AckHandle` and `Lease` for each message

### Wiring: `pgmqSourceWithShutdown`

The adapter (in `Pgmq.hs`) does not use `pgmqSource` directly; it wires `pgmqSourceWithShutdown`, which inserts a shutdown gate and selects the prefetching chunk stage. Its pipeline is:

```haskell
chunkStream                                         -- pgmqChunks OR pgmqChunksPrefetch
  & Stream.filter (not . Vector.null)               -- skip empty batches
  & Stream.takeWhileM keepChunk                     -- shutdown gate; releases undispatched chunks
  & Stream.unfoldEach (Unfold.unfoldr Vector.uncons)-- flatten Vector to elements
  & Stream.mapMaybeM (mkIngested env config)        -- convert + filter auto-DLQ'd messages
```

The `keepChunk` gate checks `shutdownVar`: on shutdown it releases any just-read, undispatched chunk (setting its visibility timeout to 0) and stops the stream.

## Type Mappings

### Message Types

| Shibuya Type | pgmq Type | Conversion |
|--------------|-----------|------------|
| `MessageId` (Text) | `MessageId` (Int64) | `show` / `reads` |
| `Cursor` | `MessageId` | `CursorInt (fromIntegral i)` |
| `Envelope.enqueuedAt` | `Message.enqueuedAt` | Direct (UTCTime) |
| `Envelope.payload` | `Message.body` | `Pgmq.unMessageBody` (JSON Value) |
| `Envelope.partition` | `headers."x-pgmq-group"` | Extract from headers object |
| `Lease.leaseId` | `MessageId` | `Text.pack (show id)` |

### Envelope Construction

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

Notes on the populated fields:

- `traceContext` is derived from the message's `traceparent`/`tracestate` header keys via `extractTraceHeaders` (or `Nothing` when absent).
- `attempt` is derived from pgmq's `readCount` via `readCountToAttempt` (readCount is 1-based, so first delivery maps to `Attempt 0`).
- `headers` is deliberately `Nothing`: the JSONB `headers` object is unordered user metadata, consumed only to derive `partition` and `traceContext`, and is not re-presented as broker headers.
- `attributes` is left empty (`HashMap.empty`) as a forward-compatible hook; there are no spec-defined pgmq messaging attributes yet.

## Ack Decision Handling

Each `AckDecision` maps to specific pgmq operations:

### AckOk

```haskell
AckOk -> deleteMessage (MessageQuery queueName msgId)
```

Message is permanently removed from the queue. Processing succeeded.

### AckRetry

```haskell
AckRetry (RetryDelay delay) ->
  changeVisibilityTimeout $ VisibilityTimeoutQuery
    { queueName = queueName,
      messageId = msgId,
      visibilityTimeoutOffset = nominalToSeconds delay
    }
```

Message becomes visible again after the specified delay. The delay is converted with `nominalToSeconds`, which **saturates at the `Int32` bounds** (rather than wrapping), so a misconfigured very-large delay produces a merely-very-long retry instead of a corrupt one. The `readCount` has already been incremented, so retries are tracked.

### AckDeadLetter

Two paths depending on configuration:

**Without DLQ:**
```haskell
AckDeadLetter reason -> archiveMessage (MessageQuery queueName msgId)
```

**With DLQ:**

Dead-lettering runs in a **single hasql transaction** (`deadLetterTransactionally`, `ReadCommitted`/`Write`) that atomically sends the DLQ copy and deletes the source row, so a message is never lost or duplicated across the two operations:

```haskell
AckDeadLetter reason -> case config.deadLetterConfig of
  Nothing      -> archiveMessage (MessageQuery queueName msgId)
  Just dlqConfig -> do
    consumerHdrs <- currentTraceHeaders
    deadLetterTransactionally env config dlqConfig msg reason
      (mergeDlqHeaders consumerHdrs msg.headers)
```

The target is selected from `dlqConfig.dlqTarget :: DeadLetterTarget`:

- `DirectQueue queueName` — sends the DLQ copy to a specific queue (`sendMessage` / `sendMessageWithHeaders`).
- `TopicRoute routingKey` — routes the DLQ copy by routing key (`sendTopic` / `sendTopicWithHeaders`).

The consumer's current trace headers are merged into the DLQ message's headers via `mergeDlqHeaders`: the consumer's active `traceparent`/`tracestate` take the active slot, and the original message's `traceparent`/`tracestate` (if present) are preserved under `x-shibuya-upstream-traceparent` / `x-shibuya-upstream-tracestate`. When there is no active span the original headers are forwarded verbatim. When headers are present the `*WithHeaders` statement variants are used; otherwise the plain variants.

DLQ payload structure:
```json
{
  "original_message": { ... },
  "dead_letter_reason": "max_retries_exceeded",
  "original_message_id": 12345,
  "original_enqueued_at": "2024-01-15T10:30:00Z",
  "read_count": 4,
  "original_headers": { ... }
}
```

### AckHalt

```haskell
AckHalt _reason ->
  let vtSeconds = maybe config.visibilityTimeout id config.haltVisibilityTimeout
   in changeVisibilityTimeout $ VisibilityTimeoutQuery
        { queueName = queueName,
          messageId = msgId,
          visibilityTimeoutOffset = vtSeconds
        }
```

The message is parked by reassigning its visibility timeout. The parking duration is **configurable**: it uses `haltVisibilityTimeout` when set, otherwise falls back to `visibilityTimeout` (there is no hardcoded 1-hour offset). After that many seconds the message becomes visible to any consumer again, independent of restart. See Design Decision #7 ("AckHalt Uses Configurable VT Extension").

## Polling Strategies

### Standard Polling

```
Poll ─► Empty? ─► Sleep ─► Poll ─► Messages ─► Process ─► Poll
             │                        │
             └────── pollInterval ────┘
```

- Client-side sleep when queue is empty
- Good for: high-throughput scenarios, consistent load
- Trade-off: wastes a round-trip when queue is empty

### Long Polling

```
Poll ─► Database blocks (up to maxPollSeconds) ─► Returns messages or timeout
                           │
              Checks every pollIntervalMs
```

- Database-side blocking until messages available
- Good for: queues that are often empty
- Trade-off: holds database connection during wait

## FIFO Support

pgmq 1.8.0+ supports grouped message ordering via the `x-pgmq-group` header.

### Throughput Optimized

```
Group A: [1] [2] [3]
Group B: [1] [2]
Group C: [1] [2] [3] [4]

Batch read (size 3): [A:1] [A:2] [A:3]  ← Same group fills batch
Next batch:          [B:1] [B:2] [C:1]  ← Move to next groups
```

Uses `readGrouped` / `readGroupedWithPoll`. Good for order-dependent workflows.

### Round Robin

```
Group A: [1] [2] [3]
Group B: [1] [2]
Group C: [1] [2] [3] [4]

Batch read (size 3): [A:1] [B:1] [C:1]  ← One from each group
Next batch:          [A:2] [B:2] [C:2]  ← Fair distribution
```

Uses `readGroupedRoundRobin` / `readGroupedRoundRobinWithPoll`. Good for multi-tenant systems.

## Shutdown Handling

```haskell
pgmqAdapter :: ... -> PgmqAdapterEnv -> PgmqAdapterConfig -> Eff es (Either PgmqConfigError (Adapter es Value))
pgmqAdapter env config = do
  shutdownVar <- newTVarIO False

  let messageSource = pgmqSourceWithShutdown env config shutdownVar

  pure $
    Right
      Adapter
        { adapterName = "pgmq:" <> queueNameToText config.queueName,
          source = messageSource,
          shutdown = atomically $ writeTVar shutdownVar True
        }
```

Shutdown flow:
1. `stopApp` calls `adapter.shutdown`
2. `shutdownVar` is set to `True`
3. The source stops at the next chunk boundary and releases any just-read, undispatched messages by setting their visibility timeout to 0
4. Ingester thread completes
5. Processor drains remaining messages in inbox
6. Handler completes final message with ack

Messages in-flight are processed to completion. Messages not yet polled remain in pgmq.

**Prefetch exception (no data loss).** When `prefetchConfig` is enabled, the polling stage buffers batches ahead of the shutdown gate. On shutdown, up to `bufferSize × batchSize` already-read messages may be sitting in that buffer and are *not* released promptly by step 3. This does **not** lose messages: a pgmq read only sets a visibility timeout, it never deletes, so those messages stay in the queue and pgmq redelivers them once their visibility timeout expires. The only effect is that their redelivery is *delayed* by up to `visibilityTimeout` seconds after a shutdown — a bounded, at-least-once-safe edge case inherent to reading ahead. See “Concurrent Prefetch” below.

## Design Decisions

### 1. Effect Integration

**Decision**: Require `Pgmq` effect in effect stack.

**Rationale**: Both libraries use effectful. This allows composition with other effects and gives users control over pool management.

**Trade-off**: Users must run `runPgmq pool` before using the adapter.

### 2. JSON Payload Type

**Decision**: Default to `Value` (aeson JSON) for message payload.

**Rationale**: pgmq messages are JSONB. Handlers can parse to domain types as needed.

**Future**: Could provide `pgmqAdapterTyped @MyMessage` variant.

### 3. Batch Flattening with unfoldEach

**Decision**: Use `Stream.unfoldEach vectorUnfold` to flatten batches.

**Rationale**: Ensures all messages from each batch are processed, not just the first. This provides up to `batchSize` x throughput improvement.

**Previous bug**: Original implementation only used `Vector.uncons` which discarded `rest`.

### 4. Automatic Dead-Lettering

**Decision**: Auto-DLQ when `readCount > maxRetries` before handler sees message.

**Rationale**: pgmq's `readCount` provides accurate retry tracking. Auto-DLQ prevents poison pills from blocking the queue.

**Implementation**: `mkIngested` returns `Nothing` for over-retry messages, filtering them from the stream.

### 5. DLQ as Optional Configuration

**Decision**: DLQ is not required. Without DLQ, dead-letter uses `archiveMessage`.

**Rationale**: Some applications prefer archiving over separate DLQ. Flexibility for different use cases.

### 6. Concurrent Prefetch (opt-in)

**Decision**: Concurrent prefetch is available via `prefetchConfig` (default `Nothing` = disabled). When enabled, the polling stage runs on a Streamly `parBuffered` worker so the next batches are read while the current messages are processed.

**Rationale / history**: An earlier `parBuffered` implementation deadlocked under the adapter's effect stack (`thread blocked indefinitely in an STM transaction`). The root cause is not Streamly: `parBuffered` forks worker threads that must unlift `Eff`, and effectful's default `SeqUnlift` strategy throws when its unlift runs off-thread. The fix runs *only the prefetch stage* under `ConcUnlift`, scoped locally via `morphInner (withUnliftStrategy (ConcUnlift Ephemeral Unlimited))`, so the non-prefetch path is unchanged (still `SeqUnlift`, no overhead).

**Trade-offs**:
- Prefetched messages have their visibility timeout ticking while buffered. Ensure `bufferSize × batchSize × avgProcessingTime < visibilityTimeout`.
- **Shutdown (no data loss)**: a shutdown can strand up to `bufferSize × batchSize` buffered messages invisible until their VT expires (see “Shutdown Handling” above). No messages are lost — they are redelivered after the visibility timeout; only redelivery is delayed. This bounded, at-least-once-safe behaviour is accepted and documented rather than engineered away, because the strand is intrinsic to reading ahead.

### 7. AckHalt Uses Configurable VT Extension

**Decision**: `AckHalt` extends VT using `haltVisibilityTimeout` when set, otherwise `visibilityTimeout`.

**Rationale**: Prevents tight retry loops during halt while keeping the parking duration explicit in configuration.
