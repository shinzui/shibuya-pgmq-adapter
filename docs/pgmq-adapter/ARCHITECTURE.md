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

The adapter constructs a Streamly stream through four layers:

### Layer 1: Chunk Polling (`pgmqChunks`)

```haskell
pgmqChunks :: Stream (Eff es) (Vector Pgmq.Message)
pgmqChunks config = Stream.repeatM poll
```

- Infinite stream of message batches
- Each poll returns a `Vector Message`
- Handles both standard and long polling
- Handles both FIFO and non-FIFO modes

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
pgmqSource :: Stream (Eff es) (Ingested es Value)
pgmqSource config =
  pgmqMessages config
    & Stream.mapMaybeM (mkIngested config)
```

- Converts each `Pgmq.Message` to `Ingested es Value`
- Filters out auto-dead-lettered messages (returns `Nothing`)
- Creates `AckHandle` and `Lease` for each message

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
      payload = Pgmq.unMessageBody msg.body
    }
```

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
      visibilityTimeoutOffset = ceiling delay
    }
```

Message becomes visible again after the specified delay. The `readCount` has already been incremented, so retries are tracked.

### AckDeadLetter

Two paths depending on configuration:

**Without DLQ:**
```haskell
AckDeadLetter reason -> archiveMessage (MessageQuery queueName msgId)
```

**With DLQ:**
```haskell
AckDeadLetter reason -> do
  let dlqBody = mkDlqPayload msg reason includeMetadata
  sendMessage (SendMessage dlqQueueName dlqBody Nothing)
  deleteMessage (MessageQuery queueName msgId)
```

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
  changeVisibilityTimeout $ VisibilityTimeoutQuery
    { queueName = queueName,
      messageId = msgId,
      visibilityTimeoutOffset = 3600  -- 1 hour
    }
```

Message is made invisible for 1 hour. When the processor restarts, the message becomes visible and can be retried.

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

### 6. Removed Lookaheading

**Decision**: Concurrent lookaheading was removed from the public adapter API.

**Rationale**: The previous Streamly `parBuffered` implementation could deadlock under the adapter's effect stack and let message visibility timeouts tick while buffered.

### 7. AckHalt Uses Configurable VT Extension

**Decision**: `AckHalt` extends VT using `haltVisibilityTimeout` when set, otherwise `visibilityTimeout`.

**Rationale**: Prevents tight retry loops during halt while keeping the parking duration explicit in configuration.
