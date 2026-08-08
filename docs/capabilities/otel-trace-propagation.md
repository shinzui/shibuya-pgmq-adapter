---
title: "OpenTelemetry trace-context propagation"
type: Capability
description: "Extracts W3C trace context from a message's headers onto the Shibuya envelope, and on the dead-letter path forwards the consumer's active trace context while preserving the producer's under x-shibuya-upstream-* keys."
generated:
  by: claude-code/1.0
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-5
provider: mori://shinzui/shibuya-pgmq-adapter
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-pgmq-adapter
interface:
  - Shibuya.Adapter.Pgmq.Convert
requires:
  - CAP-1
  - CAP-2
evidence:
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConvertSpec.hs
    proves: extractTraceHeaders reads traceparent (and optional tracestate) from the message headers object and returns Nothing when traceparent is absent or malformed.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/InternalSpec.hs
    proves: mergeDlqHeaders forwards original headers verbatim when there is no consumer span, and otherwise lets the consumer's traceparent take the active slot while stashing the original under x-shibuya-upstream-traceparent / x-shibuya-upstream-tracestate.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs
    proves: A message routed to the DLQ preserves its trace headers end-to-end against a real PostgreSQL.
---

# OpenTelemetry trace-context propagation

A behavior a consumer running under OpenTelemetry adopts by wiring a real
`Tracing` interpreter (rather than `runTracingNoop`) around the core adapter
([CAP-1: Consume a pgmq queue through Shibuya](./consume-pgmq-queue.md)):

- **On ingest**, `pgmqMessageToEnvelope` reads W3C `traceparent` / `tracestate`
  from the per-message JSONB `headers` and exposes them as the envelope's
  `traceContext`, so the handler runs in the producer's trace.
- **On the dead-letter path** ([CAP-2: Dead-letter routing](./dead-letter-routing.md)),
  the DLQ write carries the *consumer's* current trace context; the original
  producer's `traceparent` / `tracestate` are preserved under
  `x-shibuya-upstream-traceparent` / `x-shibuya-upstream-tracestate` so a DLQ
  post-mortem can still walk back to the origin. With tracing disabled or no
  active span, the original headers are forwarded verbatim.

## Limits

- **Base trace-context extraction ships from 0.1.0.0; the DLQ consumer-context
  merge is newer.** The upstream-stashing behavior on the dead-letter path was
  added around 0.5.0.0 (the shibuya-core 0.5 / DLQ-trace work). A consumer pinned
  below that gets ingest-side extraction but the pre-0.5.0.0 verbatim DLQ header
  behavior.
- **`Envelope.headers` is deliberately `Nothing`.** pgmq's headers are an
  unordered, unique-key JSONB object; they are consumed only to derive
  `partition` and `traceContext` and are not re-presented as broker headers.
  Arbitrary producer-supplied headers beyond `x-pgmq-group` / `traceparent` /
  `tracestate` are not surfaced to handlers.
- **`Envelope.attributes` is empty.** pgmq has no spec-defined typed messaging
  attributes in OpenTelemetry semantic-conventions v1.27; the field is a
  forward-compatible hook, not a populated one.
