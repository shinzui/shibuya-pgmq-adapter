# PGMQ Adapter: Dead-Letter Queues

This guide covers configuring dead-letter queue (DLQ) handling, including the topic-based routing option introduced in pgmq 1.11.0.

## When Messages Are Dead-Lettered

A message is dead-lettered when:

- `readCount` exceeds `maxRetries` (automatic, before handler sees the message)
- Handler returns `AckDeadLetter (InvalidPayload "...")`
- Handler returns `AckDeadLetter (PoisonPill "...")`
- Handler returns `AckDeadLetter MaxRetriesExceeded`
- Handler returns `AckDeadLetter (ApplicationFailure code detail)`

## Without DLQ Configuration

When `deadLetterConfig = Nothing` (the default), dead-lettered messages are archived using pgmq's `archiveMessage`. They remain in the archive table but are not sent to a separate queue.

## Direct Queue DLQ

Send dead-lettered messages to a specific queue:

```haskell
let Right dlqName = parseQueueName "orders_dlq"

let config = (defaultConfig queueName)
      { deadLetterConfig = Just $ directDeadLetter dlqName True,
        maxRetries = 3
      }
```

The `directDeadLetter` smart constructor takes:
- `QueueName` - the target DLQ
- `Bool` - whether to include original message metadata

## Topic-Routed DLQ (pgmq 1.11.0+)

Route dead-lettered messages via topic pattern matching, allowing fan-out to multiple DLQ consumers:

```haskell
let Right routingKey = parseRoutingKey "dlq.orders.failed"

let config = (defaultConfig queueName)
      { deadLetterConfig = Just $ topicDeadLetter routingKey True,
        maxRetries = 3
      }
```

Messages are sent using `pgmq.send_topic` with the given routing key. Any queues with matching topic bindings will receive the dead-lettered message.

### Example: Fan-Out DLQ with Topics

```haskell
-- Set up topic bindings (one-time, e.g., during application init)
let Right allDlqPattern = parseTopicPattern "dlq.#"
    Right ordersDlqPattern = parseTopicPattern "dlq.orders.*"
    Right allDlqQueue = parseQueueName "all_dlq"
    Right ordersDlqQueue = parseQueueName "orders_dlq"

bindQueueTopics allDlqQueue [allDlqPattern]
bindQueueTopics ordersDlqQueue [ordersDlqPattern]

-- Configure the adapter with topic-routed dead-lettering
let Right routingKey = parseRoutingKey "dlq.orders.failed"
let config = (defaultConfig ordersQueue)
      { deadLetterConfig = Just $ topicDeadLetter routingKey True
      }
```

With this setup, when an order message is dead-lettered:
- `dlq.orders.failed` matches `dlq.#` -> delivered to `all_dlq`
- `dlq.orders.failed` matches `dlq.orders.*` -> delivered to `orders_dlq`

Both queues receive the dead-lettered message.

## DLQ Message Format

### With `includeMetadata = True`

```json
{
  "original_message": { "orderId": 123, "item": "widget" },
  "dead_letter_reason": "max_retries_exceeded",
  "dead_letter_reason_code": "max_retries_exceeded",
  "dead_letter_reason_detail": null,
  "original_message_id": 456,
  "original_enqueued_at": "2024-01-15T10:30:00Z",
  "last_read_at": "2024-01-15T10:35:00Z",
  "read_count": 4,
  "original_headers": { "x-pgmq-group": "customer-1" }
}
```

### With `includeMetadata = False`

```json
{
  "original_message": { "orderId": 123, "item": "widget" },
  "dead_letter_reason": "max_retries_exceeded",
  "dead_letter_reason_code": "max_retries_exceeded",
  "dead_letter_reason_detail": null
}
```

`includeMetadata` controls only the original-message id, timestamps, read count,
and headers. `original_message` and all three reason fields are always present.

An application-owned reason is preserved without parsing its human rendering:

```json
{
  "original_message": { "orderId": 123, "item": "widget" },
  "dead_letter_reason": "keiro.router.selection.recipient_overflow: selected 101 recipients; configured limit is 100",
  "dead_letter_reason_code": "keiro.router.selection.recipient_overflow",
  "dead_letter_reason_detail": "selected 101 recipients; configured limit is 100"
}
```

### Dead-Letter Reasons

| Decision | `dead_letter_reason_code` | `dead_letter_reason_detail` | Compatibility rendering |
|----------|---------------------------|-----------------------------|-------------------------|
| `MaxRetriesExceeded` | `max_retries_exceeded` | `null` | `max_retries_exceeded` |
| `PoisonPill text` | `poison_pill` | `text` | `poison_pill: <text>` |
| `InvalidPayload text` | `invalid_payload` | `text` | `invalid_payload: <text>` |
| `ApplicationFailure code detail` | validated application code | `detail` | `<code>: <detail>` |

The detail key is always present. No detail is JSON `null`; an explicitly empty
detail is the distinct JSON string `""`.

### Querying and indexing

PGMQ stores the body in the queue table's JSONB `message` column. Operators can
query a validated queue table directly:

```sql
SELECT
  msg_id,
  message ->> 'dead_letter_reason_code' AS reason_code,
  message ->> 'dead_letter_reason_detail' AS reason_detail
FROM pgmq.q_orders_dlq
WHERE message ->> 'dead_letter_reason_code'
      = 'keiro.router.selection.recipient_overflow';
```

The adapter does not install an index. For a large retained DLQ, an operator can
add an expression index under their own schema, retention, and write-cost policy:

```sql
CREATE INDEX orders_dlq_reason_code_idx
  ON pgmq.q_orders_dlq ((message ->> 'dead_letter_reason_code'));
```

Substitute only a validated queue table name; PostgreSQL parameters cannot stand
in for identifiers.

### Migration from the legacy field

Version 0.14 dual-writes the canonical `dead_letter_reason` string and the two
structured fields. Existing readers can keep using the string while new readers
should prefer `dead_letter_reason_code` and `dead_letter_reason_detail`. During
retention overlap, old rows have only the legacy field, so use a fallback such as:

```sql
SELECT
  COALESCE(
    message ->> 'dead_letter_reason_code',
    split_part(message ->> 'dead_letter_reason', ':', 1)
  ) AS reason_code,
  CASE
    WHEN message ? 'dead_letter_reason_detail'
      THEN message ->> 'dead_letter_reason_detail'
    WHEN position(': ' IN (message ->> 'dead_letter_reason')) > 0
      THEN substring(
        (message ->> 'dead_letter_reason')
        FROM position(': ' IN (message ->> 'dead_letter_reason')) + 2
      )
    ELSE NULL
  END AS reason_detail
FROM pgmq.q_orders_dlq;
```

The legacy field is temporary but is not removed by this release. Rollback to
0.13 stops producing structured fields and does not rewrite existing rows, so
keep the fallback until all writers and retained rows are known to be migrated.

### Detail size and safety

Application detail is carried verbatim. Keep it bounded and suitable for
operators: do not put secrets, complete payloads, raw SQL, or unrestricted
backend error text in it. Larger detail increases JSON encoding, memory, network,
WAL, and retained storage linearly. Topic routing writes the payload once to
each matching target queue, multiplying those costs by the fan-out count.

## Header Preservation

When the original message has headers (e.g., `x-pgmq-group` for FIFO), the adapter preserves them on the DLQ message. This applies to both direct queue and topic-routed dead-lettering.

## DeadLetterTarget Type

The `DeadLetterTarget` sum type controls where dead-lettered messages are sent:

```haskell
data DeadLetterTarget
  = DirectQueue !QueueName   -- Send to a specific queue
  | TopicRoute !RoutingKey   -- Route via topic pattern matching (pgmq 1.11.0+)
```

Smart constructors:

```haskell
directDeadLetter :: QueueName -> Bool -> DeadLetterConfig
topicDeadLetter  :: RoutingKey -> Bool -> DeadLetterConfig
```

## Choosing Between Direct and Topic Routing

| Scenario | Recommendation |
|----------|---------------|
| Single DLQ per source queue | `directDeadLetter` |
| Multiple consumers need DLQ messages | `topicDeadLetter` |
| Centralized DLQ monitoring | `topicDeadLetter` with `dlq.#` binding |
| Simple setup, no pgmq 1.11.0 | `directDeadLetter` |
| Per-service DLQ routing | `topicDeadLetter` with service-specific patterns |
