# Changelog

## 0.8.0.0 — 2026-06-15

### Breaking Changes

- `PgmqAdapterConfig` gained a `pollRetry :: PollRetryConfig` field, and
  `pgmqAdapter` now requires `Error PgmqRuntimeError :> es` so transient poll
  errors can be caught and retried before being rethrown.

### Fixed

- Transient PGMQ poll errors are retried with bounded exponential backoff
  before the adapter gives up. The default policy makes five total attempts,
  starting at 100ms and capping at five seconds. Permanent errors and exhausted
  retry budgets still surface to shibuya supervision.

## 0.7.0.0 — 2026-06-05

### Changed

- Require `shibuya-core ^>=0.7.0.0`. `Envelope` now carries a
  `headers :: Maybe Headers` field; `pgmqMessageToEnvelope` sets it to
  `Nothing`, because pgmq messages do not carry an ordered, raw broker-header
  stream (the per-message JSONB `headers` object remains the source for the
  partition hint and W3C trace context, surfaced via `partition` and
  `traceContext`). A `Future:` note in `Shibuya.Adapter.Pgmq.Convert` records
  the option of surfacing producer-supplied pgmq headers later.
- Lower `cabal-version` from `3.14` to `3.12` in all packages so Nix
  toolchains with an older bundled Cabal can build the adapter. No
  package-description syntax requiring 3.14 was in use.

## 0.6.0.0 — 2026-05-31

Paired with `shibuya-core 0.6.0.0`.

### Compatibility

- Bumps `shibuya-core` to `^>=0.6.0.0`, `pgmq-hs` packages
  (`pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `pgmq-migration`) to
  `^>=0.3`, and the example OpenTelemetry packages to `^>=1.0`.
- Removes the `hs-opentelemetry` git source override from
  `cabal.project`; the required 1.0 packages are now available from
  Hackage. The local `cabal.project.local` Shibuya override is no
  longer needed for a release-ready build.

### OpenTelemetry

- Tracks Shibuya's `0.6.0.0` semantic-conventions change: processing
  spans now use `messaging.operation.type = "process"` instead of the
  deprecated `messaging.operation = "process"` wire key.
- The example's tracer-provider shutdown path now passes the
  OpenTelemetry 1.0 timeout argument to `shutdownTracerProvider`.

## 0.5.0.0 — 2026-05-05

Paired with `shibuya-core 0.5.0.0`.

### Breaking Changes

- Tracks the new `Envelope.attributes :: !(HashMap Text Attribute)`
  field added in `shibuya-core 0.5.0.0`. The adapter's
  `pgmqMessageToEnvelope` populates it with `HashMap.empty` —
  pgmq has no spec-defined typed messaging-attribute conventions in
  OpenTelemetry semantic-conventions v1.27, so the field is a
  forward-compatible hook. Callers that construct `Envelope` by
  record literal (e.g. test fixtures) must add
  `attributes = HashMap.empty`.
- `pgmqAdapter`, `mkAckHandle`, `mkIngested`, `pgmqSource`, and
  `pgmqSourceWithPrefetch` gain a `Tracing :> es` constraint. The
  `runApp`-based wiring already runs under `Tracing` (via
  `runTracing` or `runTracingNoop`), so most callers see no
  practical change. Callers that previously instantiated these
  with a stack lacking `Tracing` need to add it.

### Distributed Tracing

- The `AckDeadLetter` branch of `mkAckHandle` now injects the
  *failing consumer's* trace context into the DLQ message via
  `shibuya-core 0.5.0.0`'s new `currentTraceHeaders` helper. The
  consumer's `traceparent` becomes the DLQ message's active
  `traceparent`; the original producer's `traceparent` /
  `tracestate` (if present) move to the
  `x-shibuya-upstream-traceparent` /
  `x-shibuya-upstream-tracestate` keys so a DLQ post-mortem can
  walk back to the origin if it wants. When tracing is disabled
  (or there is no active span at the call site), the original
  headers are forwarded verbatim — exactly the pre-0.5.0.0
  behavior. See plan 1
  (`docs/plans/1-migrate-to-shibuya-core-0.5-and-dlq-trace.md`)
  for the rationale, and Finding F3 of the parent
  `shinzui/shibuya/docs/plans/9-otel-audit-findings.md` for the
  audit context.
- A new internal helper `Shibuya.Adapter.Pgmq.Internal.mergeDlqHeaders`
  encodes the merge rule and is exposed for unit testing. The
  `Shibuya.Adapter.Pgmq.InternalSpec` test gains five cases
  exercising the rule directly (no consumer context fall-through,
  consumer-overrides-with-stash, consumer-only-no-original,
  partial original tracestate).

### Other Changes

- Bumps `shibuya-core` build-depends pin to `^>=0.5` in the
  library and test stanzas of `shibuya-pgmq-adapter`. The
  `shibuya-pgmq-adapter-bench` and `shibuya-pgmq-example` packages
  carry the bound transitively (no in-package pins).
- `unordered-containers ^>=0.2` is now a direct build-depends of
  the library (for the `Envelope.attributes` `HashMap`) and of
  the test stanza (for `mergeDlqHeaders`'s spec).
- The `cabal.project.local` override comment is refreshed to name
  `shibuya-core 0.5.0.0`.

## 0.4.0.0 — 2026-04-29

Paired with `shibuya-core 0.4.0.0`.

### Additions

- `Envelope.attempt` is now populated from pgmq's `read_count` column
  by `pgmqMessageToEnvelope` (zero-indexed: first delivery is
  `Attempt 0`). Handlers can pass `ingested.envelope` directly to
  `Shibuya.Core.Retry.retryWithBackoff` to get exponentially-spaced
  retry delays driven by the framework's delivery counter.
- The `nominalToSeconds` helper used when extending the visibility
  timeout via `AckRetry` now defensively clamps at `Int32` bounds, so
  unsafe `BackoffPolicy { maxDelay = ... }` values cannot crash the
  adapter — they cap at `Int32` max seconds (~68 years).
- New `backoff-demo` subcommand in `shibuya-pgmq-consumer` and a
  matching `one-shot [queue]` mode in `shibuya-pgmq-simulator`. Run
  the consumer in one terminal, the simulator in another, and watch
  the message bounce through three exponentially-spaced retries
  before succeeding on the fourth delivery. See the main `shibuya`
  repo's plan `docs/plans/8-demonstrate-backoff-end-to-end.md` for
  setup and the captured live transcripts.
- Both example executables now set `LineBuffering` on stdout/stderr
  at startup so their output streams immediately under `tee`,
  redirection, or `process-compose`.

### Build

- `shibuya-core ^>=0.4.0.0` is required (gains the `Envelope.attempt`
  field and `Shibuya.Core.Retry`). The published
  `shibuya-core 0.4.0.0` now satisfies this bound on Hackage.

## 0.3.0.0 — 2026-04-24

Initial release as a standalone repository. Extracted from `shinzui/shibuya` at commit `e426e00`. No user-visible API change relative to `shibuya-pgmq-adapter 0.3.0.0` published from the monorepo — this release only decouples the release cadence. See `shibuya-pgmq-adapter/CHANGELOG.md` for the per-package history prior to the split.
