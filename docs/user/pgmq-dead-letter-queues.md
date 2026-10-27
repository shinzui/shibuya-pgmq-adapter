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
  "original_queue": "orders",
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
  "original_queue": "orders",
  "original_message": { "orderId": 123, "item": "widget" },
  "dead_letter_reason": "max_retries_exceeded",
  "dead_letter_reason_code": "max_retries_exceeded",
  "dead_letter_reason_detail": null
}
```

`includeMetadata` controls only the original-message id, timestamps, read count,
and headers. New adapter writes always include `original_queue`, `original_message`,
and all three reason fields. The compatibility helper `mkDlqPayload` keeps its old
output; `mkDlqPayloadForQueue` produces the new queue-aware envelope.

An application-owned reason is preserved without parsing its human rendering:

```json
{
  "original_queue": "orders",
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

## Failure and Retry Semantics

The adapter claims the source row and writes the DLQ copy in one transaction.
It writes only when the source delete succeeds. A send failure rolls the delete
back, leaving the source message recoverable; retry after a committed response
was lost sees that the source is already absent and does not create another
copy.

Acknowledgement operations have a bounded retry policy from `ackRetry`. When it
is exhausted, `PgmqAdapterEnv.onAckFailure` runs and the finalizer throws
`PgmqAcknowledgementException`. Applications may catch that public exception
at their outer lifecycle boundary, while current Shibuya core records it as a
failed processor lifecycle. Automatic dead-lettering invokes
`onAutoDeadLetter` only after success; failure calls `onAckFailure` and remains
visible to the caller.

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

## Browse, fetch, and redrive

`Shibuya.Adapter.Pgmq.DeadLetter` provides an in-process API in the normal build.
The inspection statements are available
in the released [`pgmq-hs`](mori://shinzui/pgmq-hs) 0.7.0.0 packages; no temporary
source project is needed.
Measured performance acceptance remains pending in
[plan 9](../plans/9-expose-adapter-managed-dead-letter-queue-browse-and-redrive.md).

Register each managed **physical** DLQ and its permitted source queues. The API
never discovers or creates queues. `registrationFromAdapterConfig` derives a
registration only for a direct target. Topic routes need explicit registrations
for every physical destination; a routing key alone cannot identify those queues.
Duplicate DLQs, empty or duplicate source lists, self-mappings and nonpositive
deadlines are configuration errors.

Supply a separately provisioned administrative pool connected to the same
database. The host owns and releases it; constructing `DeadLetterAdmin` does no
I/O and starts no polling. Use finite connection and pool acquisition deadlines
as well as the API's transaction-local statement and lock deadlines (defaults
5000ms and 1000ms). Separate connections reserve worker pool capacity, but do not
isolate PostgreSQL CPU, I/O or locks. No performance isolation claim is made until
the numeric gates in plan 9 have actual retained evidence.

The following module compiles using public exports only; its source is also
included in the normal test component as `DeadLetterExample`:

```haskell
module DeadLetterExample (configureOrders, inspectOrders) where

import Hasql.Pool qualified as Pool
import Pgmq.Types (QueueName)
import Shibuya.Adapter.Pgmq.DeadLetter

configureOrders :: Pool.Pool -> QueueName -> QueueName -> Either DlqConfigError DeadLetterAdmin
configureOrders administrativePool source dlq =
  mkDeadLetterAdmin administrativePool
    (defaultDeadLetterAdminConfig [DlqRegistration dlq [source]])

inspectOrders :: DeadLetterAdmin -> QueueName -> IO (Either DlqError DeadLetterPage)
inspectOrders admin dlq = browseDeadLetters admin dlq defaultDlqPageRequest
```

`defaultDlqPageRequest` starts at the first ID with 50 rows. Limits must be 1..500.
For the next page, pass `DlqPageRequest limit page.nextCursor`. Cursors are
exclusive and bound to a DLQ. Each call is a moving view, not a snapshot or replay
cursor; restarting from page one discovers lower IDs committed late. Limits bound
rows, not JSON bytes or database scan work. Invisible rows are included. Browsing
and `fetchDeadLetter admin dlq messageId` leave visibility times, read counts,
last-read timestamps, bodies and headers unchanged. `EntryNotFound` means absence;
a database failure remains `DatabaseError`, never an empty page or absence.

Every item retains `rawMessage` and `decodedEntry`. Decode failures remain in
page order and identify their invalid field. When either structured reason field
exists, both are required and authoritative. JSON detail is preserved as a
`Value`, including nested objects, arrays and null. The current handler's
`ApplicationFailure` still emits text detail; JSON-looking text stays text.
Only rows lacking both structured fields fall back to the legacy string, split
at its first `": "`; the result is marked `LegacyReason`.

An explicit `original_queue` must parse and appear in the registration. When it
is absent, a single permitted source is used with `ConfiguredFallback`. With
multiple permitted sources it stays `SourceUnavailable`; redrive refuses it.
Missing original count, ID and timestamps are unknown, independently of the
current DLQ row's metadata. Missing original payload is malformed; JSON null is
a valid original payload. Optional fields with invalid types are malformed.

Redrive defaults to `Left RedriveDisabled`, checked before database access.
Enable it by setting `redriveEnabled = True` on the administrative configuration
before constructing the handle. This gate is a host configuration choice, not
an authentication system: any transport the host adds must enforce its own
caller permissions. There is no arbitrary destination parameter.

`redriveDeadLetter admin dlq messageId` locks and validates the selected row,
claims it by deletion, and sends the original payload to its permitted source
in one transaction. Failed sends roll back the deletion. Missing source queues
are not created. Saved `original_headers` preserve any JSON value supported by PGMQ, including
scalars, arrays and explicit JSON null; they win over DLQ headers;
when absent, DLQ headers are used. Those fallback headers preserve grouping but
their trace context may have been replaced during dead-letter routing.

Success is `Redriven newSourceId`. Source count starts at zero with a new enqueue
time and queue-local ID, at the queue tail; the old FIFO position is not restored.
Retry the entire call after an uncertain commit. `AlreadyAbsent` means the row
is gone and causes no send; it cannot prove who removed it. Check normal source
processing records to resolve uncertainty. Do not independently resend a copied
payload. Queue recreation ends this identity lifetime: never replay an old
operator request after dropping and recreating a queue.

The durable claim prevents a second insertion for the same physical DLQ entry
after a retry or race. Each topic fan-out copy is a distinct entry: redriving two
copies can insert two source messages. This does not change the adapter's
at-least-once handler delivery or provide exactly-once application side effects.
Archives, bulk mutation, live feeds and transports are outside this API.
