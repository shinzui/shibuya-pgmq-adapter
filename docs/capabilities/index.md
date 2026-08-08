---
okf_version: "0.2"
title: "shibuya-pgmq-adapter capabilities"
---

# What shibuya-pgmq-adapter provides

`shibuya-pgmq-adapter` lets a consumer run a
[Shibuya](https://github.com/shinzui/shibuya) queue processor on top of a
[pgmq](https://github.com/pgmq/pgmq) (PostgreSQL Message Queue) queue via
[`pgmq-hs`](https://github.com/shinzui/pgmq-hs). Everything below is provided by
this repository's own code and backed by an artifact a reader can open. The
project is pre-1.0 and breaks its API on most minor releases, so every
capability is `experimental`: usable today, not yet compatibility-stable.

## Capabilities

| CAP | Capability | Since | Stability |
|-----|------------|-------|-----------|
| [CAP-1](./consume-pgmq-queue.md) | Consume a pgmq queue through Shibuya | 0.1.0.0 | experimental |
| [CAP-2](./dead-letter-routing.md) | Dead-letter routing | 0.1.0.0 | experimental |
| [CAP-3](./fifo-ordered-processing.md) | FIFO ordered processing | undetermined | experimental |
| [CAP-4](./concurrent-prefetch.md) | Concurrent prefetch | 0.10.0.0 (reintroduced) | experimental |
| [CAP-5](./otel-trace-propagation.md) | OpenTelemetry trace-context propagation | 0.1.0.0 | experimental |
| [CAP-6](./topic-based-routing.md) | Topic-based routing | 0.1.0.0 | experimental |

## Deliberately excluded

- **The benchmark suite (`shibuya-pgmq-adapter-bench`) and the example app
  (`shibuya-pgmq-example`)** are not capabilities. They are internal, unpublished
  artifacts that nothing else adopts; the benchmark appears only as *evidence*
  for CAP-3. The example is not test-covered.
- **`Shibuya.Adapter.Pgmq.Internal`** is explicitly not part of the public API
  ("may change without notice") and is not offered as a capability, though its
  functions are cited as evidence.
- **Per-module and per-function records.** Config validation, polling strategies,
  bounded transient retry, and lease extension are not separate capabilities:
  they are not adopted independently of CAP-1 and are proven by the same tests,
  so they are folded into it (granularity rule 3).
- **Anything requiring a sibling repository to be true.** Guarantees that only
  hold when Shibuya, pgmq-hs, and a consuming service cooperate belong to the
  consuming repository as use-case features, not here (provision, not
  composition).
