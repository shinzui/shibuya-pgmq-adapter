# Changelog

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
