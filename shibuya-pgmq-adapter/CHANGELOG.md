# Changelog

## 0.8.0.0 — 2026-06-15

### Breaking Changes

- `PgmqAdapterConfig` gained a `pollRetry :: PollRetryConfig` field. Callers
  that construct the config by record literal must add it (or start from a
  smart constructor / default that includes it).
- `pgmqAdapter` now requires `Error PgmqRuntimeError :> es` in its effect row
  so transient poll errors can be caught and retried before being rethrown.

### Bug Fixes

- Transient PGMQ poll errors are retried with bounded exponential backoff
  before the adapter gives up. The default policy makes five total attempts,
  starting at 100ms and capping at five seconds. Permanent errors and
  exhausted retry budgets still surface to shibuya supervision.

## 0.7.0.0 — 2026-06-05

Paired with `shibuya-core 0.7.0.0`.

### Breaking Changes

- Tracks the new `Envelope.headers :: Maybe Headers` field added in
  `shibuya-core 0.7.0.0`. `pgmqMessageToEnvelope` sets it to `Nothing`:
  pgmq does not deliver an ordered, duplicate-allowing raw broker-header
  stream. The per-message JSONB `headers` object is unordered user
  metadata and is consumed only to derive `partition` and
  `traceContext`, so it is deliberately not re-presented as broker
  headers. Callers that construct `Envelope` by record literal (e.g.
  test fixtures) must add `headers = Nothing`. A `Future:` note in
  `Shibuya.Adapter.Pgmq.Convert` records the option of surfacing
  producer-supplied pgmq headers later — deferred because the JSONB
  object's unordered, unique-key shape maps lossily onto the ordered,
  duplicate-allowing `Headers` type.

### Compatibility

- Requires `shibuya-core ^>=0.7.0.0` for the `headers` field on
  `Envelope`. The bound is bumped in the library and test stanzas.
- Lowers `cabal-version` from `3.14` to `3.12` so Nix toolchains with an
  older bundled Cabal can build the adapter. No package-description
  syntax requiring 3.14 was in use.

### Tests

- `Shibuya.Adapter.Pgmq.ConvertSpec` gains two cases asserting `headers`
  is `Nothing`, including one where the pgmq JSONB `headers` object is
  non-empty.

## 0.6.0.0 — 2026-05-31

Paired with `shibuya-core 0.6.0.0`.

### Compatibility

- Upgrades the adapter package to the current dependency family:
  `shibuya-core ^>=0.6.0.0`, `pgmq-core ^>=0.3`,
  `pgmq-hasql ^>=0.3`, `pgmq-effectful ^>=0.3`, and
  test-only `pgmq-migration ^>=0.3`.
- No adapter API changes were required. `pgmqAdapter` and the
  `Envelope` conversion behavior remain the same.

### OpenTelemetry

- Shibuya processor spans now use the stable
  `messaging.operation.type = "process"` key from
  `shibuya-core 0.6.0.0`.
- PGMQ operation spans are provided by `pgmq-effectful 0.3.0.0`, which
  builds on `hs-opentelemetry` 1.0 and supports old, stable, or
  duplicate messaging/database semantic-convention attributes via
  `OTEL_SEMCONV_STABILITY_OPT_IN`.

## 0.4.0.0 — 2026-04-29

Paired with `shibuya-core 0.4.0.0`.

### Additions

- Envelopes now carry the delivery `attempt` counter (from pgmq's
  `readCount`, zero-indexed), enabling exponential backoff via
  `Shibuya.Core.Retry`. The first delivery sees `Just (Attempt 0)`, the
  first retry `Just (Attempt 1)`, and so on.

### Internal

- `nominalToSeconds` (in `Shibuya.Adapter.Pgmq.Internal`) now clamps to
  the `Int32` range instead of silently wrapping. Misconfigured
  retry/lease durations cap at ~68 years rather than producing
  undefined behavior on the visibility-timeout offset passed to pgmq.

### Compatibility

- Requires `shibuya-core ^>=0.4.0.0` for the `Attempt` type and the
  `attempt` field on `Envelope`.

## 0.3.0.0 — 2026-04-24

Upgraded to `pgmq-hs` 0.2.0.0 series
(`pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `pgmq-migration`
all at `0.2.0.0`).

### Breaking Changes

- Consumers that pin the `Pgmq.Effectful.PgmqError` name in their own
  `runError` / `runErrorNoCallStack` stack must migrate to
  `PgmqRuntimeError`. The old type is still re-exported as a
  deprecated alias for one release.
- Spans emitted by the traced interpreter now follow OpenTelemetry
  semantic-conventions v1.24. Span names (`"publish my-queue"`,
  `"receive my-queue"`) and attribute keys (`messaging.operation`,
  `messaging.system`, `messaging.destination.name`) have changed.
  Dashboards and alerts keyed on the old names will need updating.
- Callers of `Pgmq.Effectful.Traced.sendMessageTraced` must pass an
  `OpenTelemetry.Trace.TracerProvider` instead of an
  `OpenTelemetry.Trace.Tracer`. If you only have a `Tracer` in scope,
  use `OpenTelemetry.Trace.Core.getTracerTracerProvider` to derive the
  provider.

### Other Changes

- No user-visible changes to `shibuya-pgmq-adapter`'s own API.

## 0.2.0.0 — 2026-04-22

Version bumped to track `shibuya-core` 0.2.0.0. No user-visible changes
to `shibuya-pgmq-adapter` itself.

## 0.1.0.0 — 2026-02-24

Initial release.

### New Features

- PGMQ adapter for PostgreSQL message queue integration
- Visibility timeout-based leasing with automatic retry handling
- Optional dead-letter queue support
- Configurable prefetching via PrefetchConfig
- Concurrent prefetching with streamly parBuffered
- OpenTelemetry trace context propagation
- Topic routing support (pgmq-hs 0.1.1.0)
- Comprehensive test suite with property-based and integration tests

### Bug Fixes

- Fix batch wastage using streamly unfoldEach
