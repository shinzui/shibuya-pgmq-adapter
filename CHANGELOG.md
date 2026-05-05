# Changelog

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
