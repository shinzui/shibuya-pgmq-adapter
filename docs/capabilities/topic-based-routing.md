---
title: "Topic-based routing"
type: Capability
description: "A thin management surface for pgmq topic bindings (bind, unbind, list, test-match) plus a topic routing key as a dead-letter target, so consumers can set up and dry-run AMQP-like wildcard routing."
generated:
  by: claude-code/1.0
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-6
provider: mori://shinzui/shibuya-pgmq-adapter
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-pgmq-adapter
interface:
  - Shibuya.Adapter.Pgmq
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConfigSpec.hs
    proves: The TopicRoute dead-letter target and the topicDeadLetter smart constructor build and compare as expected.
  - kind: guide
    resource: docs/user/pgmq-topic-routing.md
    proves: How to bind wildcard topic patterns to queues and use topic routing (pgmq 1.11.0+).
---

# Topic-based routing

A convenience surface layered on the core adapter
([CAP-1: Consume a pgmq queue through Shibuya](./consume-pgmq-queue.md)) for
pgmq's AMQP-like topic routing (pgmq 1.11.0+). The adapter re-exports the topic
types (`RoutingKey`, `TopicPattern`, `TopicBinding`, `RoutingMatch`) and offers
management helpers — `bindQueueTopics`, `unbindQueueTopics`,
`listQueueTopicBindings`, and `testTopicRouting` (dry-run which queues a routing
key would reach) — plus `TopicRoute` as a dead-letter target (used by CAP-2, Dead-letter routing).

## Shortest usage

```haskell
bindQueueTopics ordersQueue [pat | Right pat <- [parseTopicPattern "orders.#"]]
matches <- testTopicRouting routingKey
```

## Limits

- **This capability is thin and weakly evidenced.** The management helpers are
  small pass-throughs to `pgmq-effectful`; the actual bind / unbind / match
  behavior is proven in `pgmq-hs`, not in this repository. The only in-repo
  evidence is a smart-constructor unit test for the `TopicRoute` DLQ target plus
  the user guide — there is no integration test here exercising
  `bindQueueTopics` / `testTopicRouting` or the topic-DLQ send path against a
  database.
- **Requires a pgmq 1.11.0+ server.** Topic routing does not exist in older
  pgmq installations.
