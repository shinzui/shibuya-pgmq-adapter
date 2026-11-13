---
title: "OpenTelemetry trace-context propagation"
type: Capability
description: "Extracts W3C trace context from a message's headers onto the Shibuya envelope, lets the user choose whether the processing span joins the producer's trace or starts a linked trace, and on the dead-letter path forwards the consumer's active trace context while preserving the producer's under x-shibuya-upstream-* keys."
generated:
  by: claude-code/1.0
  at: "2026-08-08T00:00:00Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-20T21:05:00Z"
    document_timestamp: "2026-08-08T00:00:00Z"
    scope: content-and-metadata
    outcome: approved
    context: "Repository source, the full adapter test suite, capability evidence, and the EP-41 lifecycle audit."
    provider: openai
    model: gpt-6-astra
    effort: high
capabilityId: CAP-5
provider: mori://shinzui/shibuya-pgmq-adapter
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-pgmq-adapter
interface:
  - Shibuya.Adapter.Pgmq.Convert
  - Shibuya.Adapter.Pgmq.Config
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
    proves: A message routed to the DLQ preserves its trace headers end-to-end against a real PostgreSQL, and under the default policy the DLQ traceparent names the consumer's `process <processor>` span while the producer's headers move to x-shibuya-upstream-*.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConfigSpec.hs
    proves: defaultConfig carries defaultAdapterTelemetry (traceCorrelation = ParentAndLink), and a LinkOnly override validates and is kept.
  - kind: test
    resource: shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/CorrelationSpec.hs
    proves: Against a real PostgreSQL, ParentAndLink makes the processing span a child of the producer with one link to it; LinkOnly makes it a root in a new trace with the same link; each redelivery under LinkOnly is a separate linked trace while ParentAndLink keeps every delivery in the producer's trace; and under LinkOnly the DLQ traceparent names the consumer span while x-shibuya-upstream-traceparent keeps the producer header byte for byte.
---

# OpenTelemetry trace-context propagation

A behavior a consumer running under OpenTelemetry adopts by wiring a real
`Tracing` interpreter (rather than `runTracingNoop`) around the core adapter
([CAP-1: Consume a pgmq queue through Shibuya](./consume-pgmq-queue.md)):

- **On ingest**, `pgmqMessageToEnvelope` reads W3C `traceparent` / `tracestate`
  from the per-message JSONB `headers` and exposes them as the envelope's
  `traceContext`. Shibuya opens a Consumer span named `process <processor>`
  around the handler and always links it to that producer context. The
  configuration field `telemetry` (default `defaultAdapterTelemetry`, whose
  `traceCorrelation` is `ParentAndLink`) decides whether the span is also the
  producer's child:
  - `ParentAndLink` (default): the handler runs in the producer's trace, as a
    child of the producer span, and the span also links to it.
  - `LinkOnly`: the handler runs in a new trace whose root is the processing
    span, related to the producer only by the link. Choose it for delayed
    sends and long retry cycles, where a delivery would otherwise extend a
    trace that ended long ago.

  OpenTelemetry's messaging conventions allow creation-context parenting for
  single messages and recommend against it by default only when processing
  runs inside another span; Shibuya documents its choice in its ADR 0014
  (`mori://shinzui/shibuya`, `docs/adr/0014-define-consumer-correlation-and-bounded-batch-link-accounting.md`;
  artifact URI pending). When a message has no usable `traceparent`, neither
  policy adds a link and the span keeps whatever span is ambient on the
  processing thread as its parent.
- **On redelivery**, the same producer headers are read again, so every
  delivery's span links to the same producer span. Under `ParentAndLink` all
  deliveries are children in the producer's trace; under `LinkOnly` each
  delivery is its own trace.
- **On the dead-letter path** ([CAP-2: Dead-letter routing](./dead-letter-routing.md)),
  the DLQ write carries the *consumer's* current trace context; the original
  producer's `traceparent` / `tracestate` are preserved under
  `x-shibuya-upstream-traceparent` / `x-shibuya-upstream-tracestate` so a DLQ
  post-mortem can still walk back to the origin. With tracing disabled or no
  active span, the original headers are forwarded verbatim. The policy only
  changes which trace the active value names: under `ParentAndLink` it is a
  span in the producer's trace, under `LinkOnly` a span in the consumer's own
  trace, which reaches the producer through its link and through the
  preserved upstream header.

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
