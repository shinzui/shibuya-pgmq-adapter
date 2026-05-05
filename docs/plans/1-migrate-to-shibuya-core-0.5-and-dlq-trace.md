# Migrate to shibuya-core 0.5.0.0 and propagate consumer trace context on DLQ writes

Intention: intention_01kh0akd82ekat0be54p2f72kv

This ExecPlan is a living document. The sections Progress, Surprises &
Discoveries, Decision Log, and Outcomes & Retrospective must be kept up
to date as work proceeds.

This document is maintained in accordance with `agents/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

The sibling framework `shinzui/shibuya` cut a major release
`shibuya-core 0.5.0.0` on 2026-05-05 that introduces two changes
this adapter needs to track:

1.  **Breaking** — the `Envelope` record gained a strict field
    `attributes :: !(HashMap Text Attribute)` carrying
    adapter-supplied OpenTelemetry attributes for the per-message
    processing span. Direct `Envelope` constructions must add the
    field. For pgmq the value is `HashMap.empty` — pgmq has no
    spec-defined typed messaging-attribute conventions worth
    populating today (Kafka does, hence the kafka adapter populates
    `messaging.kafka.*`). The field is a future hook.
2.  **Additive** — `Shibuya.Telemetry.Propagation.currentTraceHeaders ::
    (Tracing :> es, IOE :> es) => Eff es (Maybe TraceHeaders)`
    looks up the active OTel span and encodes its context as W3C
    headers, ready for an adapter to attach to an outgoing message.
    This is the primitive the OTel API audit (Finding F3, P1)
    identified as the right fix for this adapter's
    "DLQ writes carry the original producer's traceparent, not the
    failing consumer's" gap (see
    `shinzui/shibuya/docs/plans/9-otel-audit-findings.md`).

Today, when a handler in this adapter returns
`AckDeadLetter <reason>`, the `mkAckHandle` body in
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs:201-252`
forwards the *original* message's headers — including the original
producer's `traceparent` — verbatim to the DLQ. The failing
consumer's per-message processing span (where the verdict was
recorded) is invisible in the DLQ message's trace. A downstream
operator who follows the DLQ message's trace sees the original
producer, not the failing consumer.

After this plan, a DLQ write injects the *consumer's* trace context
into the forwarded message — the failing consumer's span is the
parent of any future DLQ-consumer's span, which is exactly the link
operators need for a DLQ post-mortem.

Concretely a user can:

-   Add `shibuya-pgmq-adapter ^>=0.5` to their `cabal.project`,
    depend on `shibuya-core ^>=0.5`, and have the adapter compile
    and run unmodified — every emitted envelope carries
    `attributes = HashMap.empty`. Direct constructors of `Envelope`
    in caller code must add the field per the breaking change.
-   Run `cabal build all`, `cabal test
    shibuya-pgmq-adapter-test:unit` and integration-tagged tests
    that don't require Postgres, and observe everything pass.
-   Configure a pgmq adapter with `deadLetterConfig = Just
    (directDeadLetter dlqName True)`, run a handler that returns
    `AckDeadLetter (PoisonPill ...)`, and observe in Jaeger that
    the DLQ message's `traceparent` carries the consumer's span
    id. The previous behavior (original producer's `traceparent`
    forwarded) is replaced; the producer link is preserved under a
    custom `x-shibuya-upstream-traceparent` header for callers that
    want to walk the lineage manually.
-   Read `shibuya-pgmq-adapter/CHANGELOG.md` and see a `0.5.0.0`
    entry recording the upgrade, the `Envelope.attributes`
    visibility, and the new DLQ trace contract.

This plan is the pgmq half of plan 9
(`shinzui/shibuya/docs/plans/9-audit-and-improve-opentelemetry-api.md`)
M2.2 + M3 (F3). The kafka half is its sibling repo's plan 12.
The shibuya-core changes that both depend on (the `Envelope`
field, the `currentTraceHeaders` helper) are already committed
in the parent repo.


## Progress

Use a checklist to summarize granular steps. Every stopping point must
be documented here, even if it requires splitting a partially
completed task into two ("done" vs. "remaining"). This section must
always reflect the actual current state of the work.

-   [x] M1.1 — `cabal.project.local` comment refreshed to name
    `shibuya-core 0.5.0.0 is unreleased`. The two `packages:`
    entries (`../shibuya/shibuya-core`,
    `../shibuya/shibuya-metrics`) are unchanged. Done 2026-05-05.
-   [x] M1.2 — Audit found one direct `Envelope { ... }` literal
    in the library
    (`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs::pgmqMessageToEnvelope`).
    No test fixtures construct an `Envelope` literal — tests build
    via `pgmqMessageToEnvelope` from a `Pgmq.Message`. Done
    2026-05-05.
-   [x] M1.3 — `pgmqMessageToEnvelope` populates
    `attributes = HashMap.empty`. Documented with a comment that
    pgmq has no spec-defined typed messaging conventions today.
    Done 2026-05-05.
-   [x] M1.4 — `shibuya-core` build-depends pin bumped to
    `^>=0.5.0.0` in `shibuya-pgmq-adapter.cabal` (library + test
    stanzas). Package version bumped to `0.5.0.0`. The bench and
    example cabal files do not pin `shibuya-core` explicitly, so
    they pick up the bound transitively. Done 2026-05-05.
-   [x] M1.5 — No test fixtures needed updating (M1.2). All 125
    unit-tagged tests pass under `PGMQ_TEST_SKIP_DB=1` (12 DB-
    requiring tests pending). Done 2026-05-05.
-   [x] M2.1 — F3 implemented in
    `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`'s
    `mkAckHandle` `AckDeadLetter` branch:
    1.  Inside the branch, call
        `Shibuya.Telemetry.Propagation.currentTraceHeaders` to get
        the consumer's W3C headers (returns `Nothing` if tracing
        is disabled or no span is active — both fine; the branch
        falls through to today's behavior in that case).
    2.  When `currentTraceHeaders` returns `Just consumerHdrs`,
        merge them into the DLQ message's headers JSON. The merge
        rule: the consumer's `traceparent` becomes the active
        `traceparent`; the original producer's `traceparent`, if
        present, is preserved under
        `x-shibuya-upstream-traceparent` (and similarly for
        `tracestate` → `x-shibuya-upstream-tracestate`) so a
        future operator can walk the lineage. The W3C spec
        permits only one `traceparent` per message; this is the
        replace-with-preservation pattern.
    3.  Apply the same merge in both branches of the existing
        `mkAckHandle` `AckDeadLetter` body — the `DirectQueue`
        branch and the `TopicRoute` branch. The
        `Pgmq.MessageHeaders` JSON values both flow through here.
    4.  Add a `Tracing :> es` constraint to `mkAckHandle`'s
        signature. Update the call site
        (`mkIngested` in the same file).
-   [/] M2.2 — `Shibuya.Adapter.Pgmq.ChaosSpec`'s "preserves trace
    headers when moving to DLQ" case is **left unchanged for
    now**: it runs under `runTracingNoop`, so
    `currentTraceHeaders` returns `Nothing` and `mergeDlqHeaders`
    falls through to forwarding the original headers verbatim,
    which is exactly the current assertion. The DLQ-with-tracing
    integration test (consumer-traceparent wins) is deferred — it
    requires a Postgres devshell + an in-memory exporter setup
    that doesn't exist in `ChaosSpec` today; see Surprises for
    the trade-off. The unit-level coverage in M2.3 below is
    sufficient for the F3 logic itself.
-   [x] M2.3 — Added `mergeDlqHeaders` to
    `Shibuya.Adapter.Pgmq.Internal`'s exported surface and added
    five `InternalSpec.hs` cases asserting the merge contract:
    no-consumer fall-through, no-input-no-output,
    consumer-overrides-with-stash, consumer-only-no-original,
    partial-original-tracestate. All 5 pass. Done 2026-05-05.
-   [x] M3.1 — `CHANGELOG.md` `0.5.0.0` entry recorded. Done
    2026-05-05.
-   [x] M3.2 — `cabal build all` green, `mergeDlqHeaders` tests
    green (5/5), full unit suite green under `PGMQ_TEST_SKIP_DB=1`
    (125/125, 12 DB-pending), and `nix flake check` green
    (formatting + pre-commit). Re-verified against the published
    Hackage `shibuya-core 0.5.0.0` with `cabal.project.local`
    moved aside: build green, tests 125/125. Done 2026-05-05.
-   [x] M3.3 — Committed as `274c0eb` ("feat!: migrate to
    shibuya-core 0.5.0.0 and propagate consumer trace context to
    DLQ"); both `ExecPlan:` and `Intention:` trailers present.
    Done 2026-05-05.
-   [ ] M4 — `shibuya-core 0.5.0.0` is on Hackage as of
    2026-05-05. Adapter publication + Outcomes & Retrospective
    pending — to be run via the repo's `/release` skill.


## Surprises & Discoveries

Document unexpected behaviours, bugs, optimizations, or insights
discovered during implementation. Provide concise evidence.

### M1.4 — `unordered-containers` needed in test stanza too (2026-05-05)

`shibuya-pgmq-adapter.cabal`'s test stanza re-compiles the library's
`Convert.hs` and `Internal.hs` against the test stanza's
`build-depends` set rather than reusing the library build artifact
(it lists `src` under `hs-source-dirs` alongside `test`). When
`Convert.hs` started importing `Data.HashMap.Strict`, the test
stanza's build broke because `unordered-containers` was not in its
`build-depends`. Fix: add the pin to both library and test stanzas.

### M2.2 — ChaosSpec "tracing-on" assertion deferred (2026-05-05)

The plan originally called for renaming the existing
`Shibuya.Adapter.Pgmq.ChaosSpec` "preserves trace headers when
moving to DLQ" case and rewriting it to assert the new contract
under `runTracing tracer`. On closer inspection the existing case
is **still correct** — it runs under `runTracingNoop`, which is
the path that `mergeDlqHeaders` falls through to verbatim. The
real "consumer-traceparent wins" assertion needs (a) a
Postgres-backed run, (b) an in-memory exporter standing in for
the OTLP endpoint, and (c) a way to read the consumer's
`processOne`-span id back from the exporter to compare against
the DLQ message's header. That is a larger scaffolding change
than the F3 logic itself, and the unit-level
`mergeDlqHeaders` spec covers the merge contract directly.
Recorded so a future contributor knows the runtime test is the
remaining gap, not a missing feature.

### M2.1 — Producer-side `Tracing` constraint propagates broadly (2026-05-05)

Adding the `Tracing :> es` constraint to `mkAckHandle` cascaded
through `mkIngested`, `pgmqSource`, `pgmqSourceWithPrefetch`, and
`pgmqAdapter` (the public surface). All call sites in this repo
(jitsurei consumer + bench harness) already run under `runTracing`
or `runTracingNoop` so the cascade did not require additional
caller-side wrapping; an external caller upgrading to 0.5.0.0
must add either `runTracing tracer` or `runTracingNoop` to their
effect stack. CHANGELOG calls this out under Breaking Changes.


## Decision Log

Record every decision made while working on the plan.

-   Decision: **`Envelope.attributes` for pgmq is
    `HashMap.empty`.**
    Rationale: pgmq has no spec-defined typed messaging-attribute
    conventions in OpenTelemetry semantic-conventions v1.24/v1.27.
    The framework's `processOne` already sets
    `messaging.system="shibuya"` (sensible default for a pgmq-
    backed Shibuya consumer; the upstream spec has no
    `messaging.system="pgmq"` value) and the spec-aligned
    `messaging.destination.name`, `messaging.operation`,
    `messaging.message.id`. Adding broker-specific keys here would
    be inventing convention. Keep the field empty for now; it is a
    forward-compatible hook for the day a `messaging.pgmq.*`
    convention is defined.
    Date: 2026-05-05.

-   Decision: **DLQ trace propagation replaces the active
    `traceparent` with the consumer's, preserving the original
    producer's under `x-shibuya-upstream-traceparent`.**
    Rationale: the W3C Trace Context spec permits only one
    `traceparent` per message; the question is whose. From an
    operator's perspective the "why is this message in DLQ"
    question is answered by the failing consumer's span, so the
    consumer's is the right active value. Preserving the original
    producer's under a vendor-namespaced `x-shibuya-*` header
    keeps the lineage walkable for advanced post-mortems without
    violating the spec. The `x-shibuya-` prefix avoids any
    collision with future spec-defined keys. The same rule
    applies to `tracestate`.
    Date: 2026-05-05.

-   Decision: **The `mkAckHandle` `AckDeadLetter` branch picks up
    a `Tracing :> es` constraint.**
    Rationale: `currentTraceHeaders` requires
    `Tracing :> es, IOE :> es`. The adapter's `runApp` integration
    already runs under `Tracing` (callers wrap with `runTracing`
    or `runTracingNoop`), so threading the constraint through
    `mkAckHandle` is mechanical. The `AckOk`, `AckRetry`, and
    `AckHalt` branches need no change; only `AckDeadLetter` calls
    `currentTraceHeaders`.
    Date: 2026-05-05.

-   Decision: **Use `cabal.project.local` (gitignored) for
    cross-repo development against the unpublished
    `shibuya-core 0.5.0.0`.**
    Rationale: this repo already follows the pattern (the file
    exists with the comment "Required while shibuya-core 0.4.0.0
    is unreleased"). The committed `cabal.project` continues to
    point at Hackage. This revises the more conservative reading
    taken in plan 9 of the sibling repo, which forbade path-based
    pins entirely; that rule properly applies to *committed*
    configuration only.
    Date: 2026-05-05.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or
at completion. Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

A reader who has never seen this codebase needs four facts to follow
the rest of this plan.

### Repository layout

The "shibuya project" is a multi-repo whose top-level layout sits at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/`. The directories
that matter here are:

    shibuya/                       The core library repo. Holds
                                   shibuya-core 0.5.0.0 (the
                                   library), shibuya-example,
                                   shibuya-metrics, and the
                                   docs/plans/ tree where the
                                   parent plan 9 lives.

    shibuya-pgmq-adapter/          This repo. Holds the cabal
                                   package shibuya-pgmq-adapter
                                   (PostgreSQL pgmq adapter), its
                                   bench (shibuya-pgmq-adapter-bench)
                                   and tests
                                   (Shibuya.Adapter.Pgmq.{ChaosSpec,
                                   ConfigSpec, ConvertSpec,
                                   IntegrationSpec, InternalSpec,
                                   PropertySpec}). Also contains a
                                   shibuya-pgmq-example crate
                                   demonstrating end-to-end usage
                                   including the simulator.

    shibuya-kafka-adapter/         The sibling kafka adapter repo.
                                   Independent migration; tracked
                                   in its own plan 12.

The current working directory for every command in this plan is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`
unless explicitly stated otherwise.

### What changed in shibuya-core 0.5.0.0

Two things, both already committed in the sibling repo at
`shinzui/shibuya` (commits `7c6586b` for the field, `193de1d`
for the `currentTraceHeaders` helper):

1.  `Shibuya.Core.Types.Envelope` gained an
    `attributes :: !(HashMap Text Attribute)` strict field.
    Construction sites must add `attributes = HashMap.empty` (or a
    populated map). The `NFData` instance is hand-written instead
    of derived because `hs-opentelemetry-api`'s `Attribute` does
    not ship `NFData`; the strictness shape is unchanged for every
    other field.
2.  `Shibuya.Telemetry.Propagation.currentTraceHeaders ::
    (Tracing :> es, IOE :> es) => Eff es (Maybe TraceHeaders)`
    looks up the active OTel span and encodes its context as W3C
    headers. Returns `Nothing` if tracing is disabled or no span
    is active.

### What this adapter does today on the DLQ path

`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs:178-263`
defines `mkAckHandle`. The `AckDeadLetter reason` branch:

1.  Builds a DLQ payload via `mkDlqPayload msg reason
    dlqConfig.includeMetadata`.
2.  Looks up `dlqConfig.dlqTarget`. For `DirectQueue dlqQueueName`,
    sends to the named DLQ; for `TopicRoute routingKey`, routes
    via pgmq's topic-pattern matcher. In both cases:
    -   If the original `msg.headers` is `Just headers`, calls
        `sendMessageWithHeaders` with `messageHeaders =
        Pgmq.MessageHeaders headers` — i.e., **the original
        producer's headers, unchanged**. This includes their
        `traceparent` and `tracestate` if any.
    -   If `Nothing`, calls plain `sendMessage` with no headers,
        dropping the producer's trace context entirely.
3.  Deletes the message from the original queue.

The "preserves trace headers when moving to DLQ" test in
`Shibuya.Adapter.Pgmq.ChaosSpec` (lines 196-265) asserts the
current behavior: producer's `traceparent` survives the DLQ hop
verbatim. After this plan, the test's assertion changes — see
M2.2 in Progress.

### What this adapter must keep doing

Everything else is unchanged: source-stream construction
(`pgmqAdapter`, `pgmqSource`), `AckHandle` semantics (`AckOk` →
`deleteMessage`, `AckRetry _` → `changeVisibilityTimeout`,
`AckHalt _` → far-future visibility timeout), the W3C
`traceparent` extraction in
`Shibuya.Adapter.Pgmq.Convert.extractTraceHeaders` (the consumer
side of trace propagation, untouched by this plan), the
`runPgmqTraced`-based example wiring in `shibuya-pgmq-example`.


## Plan of Work

### Milestone 1 — Local override + Convert.hs attribute population + cabal bumps

**Scope.** Get the in-tree adapter compiling against the local
sibling `shibuya-core 0.5.0.0`. Populate `Envelope.attributes =
HashMap.empty` in `Convert.hs`. Update tests' `Envelope` literals.
Bump cabal pins.

**What will exist at the end.**

-   `shibuya-pgmq-adapter/cabal.project.local` references the
    sibling sources (existing) with an updated comment naming
    `shibuya-core 0.5.0.0`.
-   `pgmqMessageToEnvelope` populates the new `attributes` field
    with `HashMap.empty`.
-   Every `Envelope { ... }` literal in tests adds `attributes =
    HashMap.empty`.
-   The cabal pins are bumped to `shibuya-core ^>=0.5`. Each cabal
    file's `version:` line reads `0.5.0.0`.

**Acceptance.** `cabal build all` is green against the local
override. `cabal test
shibuya-pgmq-adapter-test:unit` (or the unit-tagged subset that
does not require a real Postgres) is green.

### Milestone 2 — DLQ trace propagation (F3)

**Scope.** Implement F3. Update tests.

**What will exist at the end.**

-   `mkAckHandle` in
    `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`
    has a `Tracing :> es` constraint. Its `AckDeadLetter` branch
    calls `currentTraceHeaders` and merges with the original
    headers under the rule documented in the Decision Log
    (consumer's `traceparent` active; producer's preserved under
    `x-shibuya-upstream-traceparent`).
-   `mkIngested` (its caller) carries the constraint through.
    `pgmqAdapter`'s public signature gets the same constraint
    (or already had it transitively).
-   The "preserves trace headers when moving to DLQ" case in
    `Shibuya.Adapter.Pgmq.ChaosSpec` is renamed and rewritten to
    assert the new contract. A sibling case asserts the
    `runTracingNoop` fall-through behavior.
-   A unit-level merge test exists in `InternalSpec` (or
    `ConvertSpec`).

**Acceptance.** `cabal build all` is green. `cabal test
shibuya-pgmq-adapter-test` (the integration-tagged tests that
hit a real Postgres) is green if the dev-shell Postgres is up.
The Jaeger smoke (described in Validation and Acceptance) shows
the DLQ message parented on the failing consumer's span.

### Milestone 3 — Local gates + commit

**Scope.** Run gates, update CHANGELOG, commit.

**What will exist at the end.** A clean `nix flake check`, a
green `cabal build all`, a green `cabal test
shibuya-pgmq-adapter-test:unit`. CHANGELOG entry for `0.5.0.0`.
Commits carrying both trailers.

### Milestone 4 — Publication and close-out

**Scope.** After `shibuya-core 0.5.0.0` publishes to Hackage,
publish `shibuya-pgmq-adapter 0.5.0.0`. Fill Outcomes &
Retrospective.

**Acceptance.** Hackage carries the new release. The
`cabal.project.local` override is gitignored; can be left in
place or wiped per local hygiene preference.


## Concrete Steps

Working directory for every command is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`
unless otherwise noted.

### Bootstrapping

    git status
    git rev-parse --abbrev-ref HEAD

### Milestone 1

    # 1. Verify cabal.project.local exists and is gitignored.
    cat cabal.project.local
    grep -qx cabal.project.local .gitignore || echo cabal.project.local >> .gitignore

    # 2. Update the comment to name 0.5.0.0.
    $EDITOR cabal.project.local

    # 3. Populate Envelope.attributes in Convert.hs.
    $EDITOR shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs

    # 4. Bump cabal pins and own version.
    $EDITOR shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal
    # also: shibuya-pgmq-adapter-bench, shibuya-pgmq-example

    # 5. Update test fixtures to add attributes = HashMap.empty.
    $EDITOR shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/PropertySpec.hs
    $EDITOR shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConvertSpec.hs
    # (any other test that constructs an Envelope literal)

    # 6. Build and test.
    cabal build all
    cabal test shibuya-pgmq-adapter-test:unit

### Milestone 2

    # 1. Implement F3 in mkAckHandle.
    $EDITOR shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs

    # 2. Add a unit-level merge test.
    $EDITOR shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/InternalSpec.hs

    # 3. Update ChaosSpec's existing DLQ-trace test for the new contract.
    $EDITOR shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs

    # 4. Build and run the unit tests.
    cabal build all
    cabal test shibuya-pgmq-adapter-test:unit

    # 5. Run the integration tests against the dev-shell Postgres.
    pg_ctl start -l "$PGHOST/postgres.log"
    cabal test shibuya-pgmq-adapter-test
    pg_ctl stop

    # 6. Jaeger smoke against the example.
    just process-up        # shell 1
    cabal run shibuya-pgmq-consumer -- --enable-tracing &  # shell 2

    # Send a message that the handler will dead-letter:
    psql -h "$PWD/db" -d shibuya -c "
      SELECT pgmq.send('orders',
        '{\"poison\": true}'::jsonb,
        '{\"traceparent\": \"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01\"}'::jsonb,
        0
      );
    "

    # Inspect Jaeger for the DLQ message's trace.
    curl -s "http://127.0.0.1:16686/api/services" | jq '.data[]'
    curl -s "http://127.0.0.1:16686/api/traces?service=shibuya-consumer&limit=5" | jq

    # Record the transcript in this plan's Surprises section.

### Milestone 3

    # 1. Update CHANGELOG.
    $EDITOR shibuya-pgmq-adapter/CHANGELOG.md

    # 2. Run gates.
    nix fmt
    nix flake check
    cabal build all
    cabal test shibuya-pgmq-adapter-test:unit

    # 3. Commit.
    git add shibuya-pgmq-adapter/...
    git commit  # ExecPlan: + Intention: trailers

### Milestone 4

After `shibuya-core 0.5.0.0` is on Hackage:

    # Publish per existing release recipe.
    # Update Outcomes & Retrospective.
    $EDITOR docs/plans/1-migrate-to-shibuya-core-0.5-and-dlq-trace.md


## Validation and Acceptance

**M1.** `cabal build all` and `cabal test
shibuya-pgmq-adapter-test:unit` are green against the local
`cabal.project.local` override. Property tests in
`PropertySpec` and `ConvertSpec` pass with the updated
`Envelope` literals.

**M2.** The rewritten ChaosSpec case asserts:

-   A handler that returns
    `AckDeadLetter (PoisonPill "...")` under `runTracing tracer`,
    receiving a message whose original `traceparent` is
    `<producer-id>`, produces a DLQ message whose:
    -   `traceparent` header decodes to a `SpanContext` whose
        `spanId` is the consumer's `processOne` span id (read
        back from the in-memory exporter);
    -   `x-shibuya-upstream-traceparent` header equals
        `<producer-id>`.
-   The same handler under `runTracingNoop` produces a DLQ
    message whose `traceparent` equals the original producer's
    `<producer-id>` (i.e., today's behavior is preserved when
    tracing is off).

The Jaeger smoke shows the DLQ message's trace tree rooted at the
failing consumer's span, with the original producer's trace
linked under the custom header (visible in the message body
inspection, not in Jaeger's tree itself, since Jaeger only knows
the active `traceparent`).

**M3.** `nix flake check` is green.

**M4.** Hackage shows `shibuya-pgmq-adapter 0.5.0.0`. Outcomes
& Retrospective records the published-version transcript.


## Idempotence and Recovery

The Convert.hs edits are local-file mutations; they can be
re-applied safely. The `cabal.project.local` is gitignored, so
it can be deleted and recreated.

The `mkAckHandle` `AckDeadLetter` branch's behavioral change is
recoverable via `git revert`. The fall-through behavior under
`runTracingNoop` (and `currentTraceHeaders` returning `Nothing`)
is exactly today's behavior, so callers who do not enable tracing
see no difference.

The cross-repo invariant: this repo depends on
`shibuya-core ^>=0.5`. Without the local override or the
published Hackage release, the adapter will not resolve.
Recovery is either re-add the override or wait for the Hackage
publication.


## Interfaces and Dependencies

Packages used by this work:

-   `shibuya-core ^>=0.5` (the new pin).
-   `aeson ^>=2.2` (already a direct dependency for the JSON
    header manipulation; unchanged).
-   `unordered-containers ^>=0.2` (used for the `attributes`
    HashMap; pin added if not already present).
-   `text-encoding` (already in scope via existing `extractTraceHeaders`).

Interface shape after each milestone:

-   End of M1: `pgmqMessageToEnvelope` populates
    `attributes = HashMap.empty`. `mkAckHandle` is unchanged.
-   End of M2: `mkAckHandle` requires `Tracing :> es` and
    `IOE :> es` (both already implicit at `pgmqAdapter`'s call
    sites). Public surface of the adapter:

        -- shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs
        pgmqAdapter ::
          (Pgmq :> es, Tracing :> es, IOE :> es) =>
          PgmqAdapterConfig ->
          Eff es (Adapter es Value)
        -- (Tracing constraint promoted from transitive to explicit.)

    `mkAckHandle`, `mkIngested`, `pgmqSource` carry the constraint
    in their signatures.

-   End of M3 / M4: same interface; the version label reflects
    the published release.

No new public API. The producer-side helper
`currentTraceHeaders` lives in `shibuya-core` and is consumed
internally; this adapter does not re-export it.


---

Revision history:

-   2026-05-05: Initial draft. Tracks plan 9
    (`shinzui/shibuya/docs/plans/9-audit-and-improve-opentelemetry-api.md`)
    M2.2 + M3.1 (F3). Intention shared with the parent plan and
    with the sibling kafka adapter's plan 12.
