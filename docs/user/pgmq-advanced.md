# PGMQ Adapter: Advanced Configuration

This guide covers FIFO ordering, lease extension, and tuning.

## FIFO Ordering

pgmq 1.8.0+ supports grouped message ordering via the `x-pgmq-group` header.

### Setup

```haskell
let config = (defaultConfig queueName)
      { fifoConfig = Just FifoConfig
          { readStrategy = RoundRobin  -- or ThroughputOptimized
          }
      }
```

Messages must have the `x-pgmq-group` header. The adapter extracts it and exposes it as `ingested.envelope.partition`.

### ThroughputOptimized

Fills each batch from the same group before moving to the next:

```
Groups:     A:[1,2,3]  B:[1,2]  C:[1,2,3,4]
Batch 1:    [A:1, A:2, A:3]
Batch 2:    [B:1, B:2, C:1]
Batch 3:    [C:2, C:3, C:4]
```

Best for: order processing, document workflows - when completing one group matters.

### RoundRobin

Fair distribution across groups:

```
Groups:     A:[1,2,3]  B:[1,2]  C:[1,2,3,4]
Batch 1:    [A:1, B:1, C:1]
Batch 2:    [A:2, B:2, C:2]
Batch 3:    [A:3, C:3, C:4]
```

Best for: multi-tenant systems, load balancing - when fairness across groups matters.

## Lease Extension

For queues with visibility timeouts, extend the lease for long-running operations:

```haskell
handleLongRunning :: Handler '[IOE] BigJob
handleLongRunning ingested = do
  let job = payload (envelope ingested)

  -- Extend lease for long operations
  case lease ingested of
    Nothing -> pure ()  -- Adapter doesn't support leases
    Just l  -> do
      -- Extend by 5 minutes before starting
      leaseExtend l 300

  -- Long running operation
  result <- runExpensiveJob job

  pure $ case result of
    Right () -> AckOk
    Left err -> AckRetry (RetryDelay 60)
```

The PGMQ adapter always provides a lease. Extending the lease uses pgmq's absolute visibility-timeout API and never shortens an already-extended lease.

## Tuning Guidelines

### Visibility Timeout

| Workload | Recommended VT |
|----------|----------------|
| Fast handlers (< 1s) | 30 seconds |
| Medium handlers (1-10s) | 60 seconds |
| Long-running (> 10s) | 2-3x expected max time |
| Variable length | Use lease extension |

### Batch Size

| Scenario | Recommended Size |
|----------|------------------|
| Simple processing | 1-10 |
| High throughput | 50-200 |
| Maximum throughput | 500-1000 |
| Memory constrained | 10-50 |

### Polling Strategy

| Queue Behavior | Recommended Strategy |
|----------------|----------------------|
| Usually has messages | StandardPolling (100-500ms) |
| Often empty | LongPolling (5-10s max) |
| Bursty | LongPolling with short max |
| High throughput | StandardPolling (10-50ms) |

## Configuration Examples

### High-Throughput Processing

```haskell
let config = (defaultConfig queueName)
      { batchSize = 100,
        visibilityTimeout = 120,  -- 2 minutes
        polling = StandardPolling { pollInterval = 0.1 }  -- 100ms
      }
```

### Multi-Tenant FIFO

```haskell
let config = (defaultConfig queueName)
      { batchSize = 20,
        visibilityTimeout = 60,
        fifoConfig = Just FifoConfig { readStrategy = RoundRobin },
        maxRetries = 5
      }
```

### Order Processing (Strict FIFO with DLQ)

```haskell
let config = (defaultConfig queueName)
      { batchSize = 50,
        visibilityTimeout = 300,  -- 5 minutes
        fifoConfig = Just FifoConfig { readStrategy = ThroughputOptimized },
        deadLetterConfig = Just $ directDeadLetter ordersDlq True,
        maxRetries = 3
      }
```
