---
id: 5
slug: preserve-structured-dead-letter-reasons-in-pgmq-dlq-payloads
title: "Preserve structured dead-letter reasons in PGMQ DLQ payloads"
kind: exec-plan
created_at: 2026-08-10T20:25:52Z
intention: "intention_01kzpnmd43eb5beah008ctbcds"
---

# Preserve structured dead-letter reasons in PGMQ DLQ payloads

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a Shibuya handler can reject a syntactically valid message with an
application-owned reason such as `keiro.router.selection.recipient_overflow`, and an operator
reading the PGMQ dead-letter queue (DLQ) can query that stable code separately from its explanatory
detail. The adapter will consume the public API released in
`mori://shinzui/shibuya/packages/shibuya-core` 0.9.0.0 instead of matching Shibuya's reason
constructors itself.

This release is deliberately compatible with existing DLQ readers. Every newly written DLQ body
will retain the existing canonical text field and add two structured fields:

```json
{
  "dead_letter_reason": "keiro.router.selection.recipient_overflow: selected 101 recipients; configured limit is 100",
  "dead_letter_reason_code": "keiro.router.selection.recipient_overflow",
  "dead_letter_reason_detail": "selected 101 recipients; configured limit is 100"
}
```

`dead_letter_reason_detail` is always present and is JSON `null` for a reason such as
`MaxRetriesExceeded` that has no detail. The `includeMetadata` setting continues to control only
the original-message metadata; it never removes the three reason fields. Existing readers can
continue using `dead_letter_reason`, while new readers can migrate to the structured fields. The
later, intentionally breaking removal is not part of this plan; it is gated separately in
[Plan 6](./6-remove-the-legacy-dead-letter-reason-field-after-structured-rollout.md).

A user can see the feature working by running the PostgreSQL-backed test that sends an
`ApplicationFailure` through the real adapter, reading the resulting DLQ row, and observing the
exact code, detail, and compatibility rendering above. Unit and property tests prove the same
contract for all built-in reasons. A focused benchmark records the pure JSON serialization cost
and size increase, while existing database tests prove that the send/delete transaction,
idempotent acknowledgement, retries, and trace propagation do not change.


## Progress

- [x] (2026-08-10T20:57:14Z) M1 release verification — Mori located the registered Shibuya source;
  Hackage reported 0.9.0.0 as the newest normal core/metrics version; upstream `v0.9.0.0` resolved
  to annotated tag object `9d3e85b6` and commit `d958a574`; and the tagged public API matched this
  plan.
- [x] (2026-08-10T21:02:35Z) M1 contract preparation — repaired and sharpened IR-1, registered
  this plan for its typed `targetPlan`, updated all Shibuya bounds and adapter version/changelogs,
  passed Mori/OKF validation, and built the whole workspace with Cabal resolving
  `shibuya-core-0.9.0.0` and `shibuya-metrics-0.9.0.0` from Hackage.
- [x] (2026-08-10T21:06:30Z) M2 — replaced the production constructor match with Shibuya's total
  public projections; added exact four-constructor, null/empty, Unicode/escaping, metadata-mode,
  generator/shrinker, and projection-derived property coverage; built the whole workspace; and ran
  the non-database suite with 160 examples, zero failures, and 20 expected database-pending cases.
- [x] (2026-08-10T21:17:02Z) M3 — proved the representative application reason through the real
  adapter and PostgreSQL JSONB operators; measured JSONB size plus fully encoded serialization;
  updated user, configuration, architecture, internal, and capability documentation; passed strict
  capability validation; and ran 161 database-backed examples with zero failures.
- [x] (2026-08-10T21:24:42Z) M4 pre-publication gates — dated both 0.14.0.0 changelogs; passed
  formatting, Cabal package checking, both strict OKF bundle checks, Mori validation, the complete
  workspace build, 161 database-backed examples, and `nix flake check`; then built and inspected
  the source and Hackage Haddock archives.
- [x] (2026-08-10T21:26:56Z) M4 — published source and Haddocks to Hackage, pushed annotated tag
  `v0.14.0.0` and the GitHub release, closed IR-1 with release/test evidence, marked this registered
  plan complete, and found no established local ADR destination during the final distillation pass.


## Surprises & Discoveries

- The initial improvement-request document does not pass its own local validator. The command
  `mori improvement-requests validate --path .` reports that its `origin` points at a disallowed
  improvement-request artifact kind. The package that supplies the request is a valid origin;
  the body can and should keep the more specific cross-request URI.

  ```text
  IR-1: origin has a disallowed artifact kind:
  mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2
  ```

- The released core renderer is not a meaningful performance risk by itself. Shibuya's release
  plan records `render-application-failure` at 41.0 ns with 215 bytes allocated and no copied live
  data. Code validation measured 232 ns, but applications are explicitly expected to validate a
  finite code set at startup and reuse the opaque values rather than validate per message.
- For the representative 41-byte code and 48-byte detail, adding
  `dead_letter_reason_code` and `dead_letter_reason_detail` alongside the old field adds exactly
  149 bytes to compact, unescaped JSON text. PostgreSQL JSONB, tuple, WAL, and TOAST sizes are not
  identical to JSON text size, so the implementation records actual `pg_column_size(message)` as
  database evidence instead of pretending 149 is the physical storage delta.
- No local `docs/adr/` directory exists and `mori show --full` reports no ADR bundle. There is no
  local ADR to cite at authoring time. The dual-write/removal boundary is a durable decision; the
  implementer must repeat the ADR discovery and create an ADR only if the repository has adopted
  an ADR convention by then or if one is deliberately introduced as part of implementation.
- Mori rejects a repository-relative `targetPlan` frontmatter value even when it names a plan in
  the same repository. Its improvement-request contract requires a canonical plan artifact URI
  and exact registry membership. The initial literal value failed with:

  ```text
  IR-1: targetPlan has a disallowed artifact kind:
  docs/plans/5-preserve-structured-dead-letter-reasons-in-pgmq-dlq-payloads.md
  ```
- The local Cabal package index initially ended at Shibuya 0.8 even though Hackage already listed
  0.9.0.0. `cabal update` advanced the index state from `2026-08-10T19:45:30Z` to
  `2026-08-10T20:30:45Z`; the same unchanged bounds then resolved and built both 0.9 packages.
  The production and property-test constructor matches emitted the expected incomplete-pattern
  warnings for `ApplicationFailure`, confirming the precise Milestone 2 work rather than exposing
  another compatibility failure.
- The representative row measured 321 bytes with the dual-write JSONB body and 168 bytes for the
  legacy-shaped control under the same ephemeral PostgreSQL, a 153-byte physical JSONB increase.
  The compact encoded JSON values were 306 and 157 bytes respectively, retaining the predicted
  149-byte difference. These measurements are diagnostics, not stable storage guarantees.
- The pure benchmark completed all six cases with no database connection. Results were:

  ```text
  case                        bytes legacy/dual/delta    time legacy/dual       allocation legacy/dual
  max-retries                 86 / 168 / 82              495 ns / 939 ns         6.2 KB / 8.0 KB
  representative-application 157 / 306 / 149            594 ns / 1.17 us       6.4 KB / 8.5 KB
  application-8k-detail       8301 / 16594 / 8293        11.4 us / 21.7 us      52 KB / 62 KB
  ```

  The 8 KiB case shows the expected linear copying rather than repeated code validation or
  nonlinear work. The representative dual-write encoder is about 0.66% of the repository's
  same-machine 177 us single-send benchmark, well below the five-percent investigation gate.
- `cabal check` reported no package warnings. The inspected 0.14.0.0 source archive contains the
  dated package changelog, exact 0.14 version, `shibuya-core ^>=0.9.0.0` bounds in both library and
  test stanzas, and the changed production/test sources. Hackage-mode Haddock generation completed
  with 100% coverage for `Config` and `Convert` and 85% for the umbrella module; its warnings are
  pre-existing unresolved or ambiguous cross-package links, not missing pages or build failures.
- Hackage candidate inspection showed the exact 0.14 version, 0.9 bounds, and dated changelog before
  publication. After source and documentation publication, Hackage's authoritative preferred
  metadata listed 0.14.0.0 as a normal version. Annotated tag object `2b700942` peels to release
  commit `3016523`, and the non-draft, non-prerelease GitHub release was published from that tag.


## Decision Log

- Decision: The compatible release always writes the legacy rendered field and two top-level
  structured fields; it does not replace the legacy string with an object.
  Rationale: Retaining `dead_letter_reason :: JSON string` lets deployed readers upgrade without
  coordination. Top-level code and detail are directly queryable with PostgreSQL's `->>` operator
  and do not require parsing the human rendering. Changing the old field's JSON type would be an
  immediate breaking change and defeat the rollout window.
  Date: 2026-08-10.

- Decision: `dead_letter_reason_detail` is always present and uses JSON `null` for `Nothing`.
  Rationale: A fixed key set is easier to document, test, and consume than distinguishing omitted
  from null. It also mirrors Shibuya's `deadLetterReasonDetail :: DeadLetterReason -> Maybe Text`
  exactly. Empty text remains an empty JSON string and is not converted to null.
  Date: 2026-08-10.

- Decision: Production serialization uses only `deadLetterReasonCode`, `deadLetterCodeText`,
  `deadLetterReasonDetail`, and `renderDeadLetterReason`; tests may enumerate the released 0.9
  constructors.
  Rationale: The public projections are total and keep semantic ownership in Shibuya. Test data
  still must deliberately exercise each released semantic variant. The test module will promote
  incomplete-pattern warnings to errors, so a future PVP-breaking reason extension cannot be
  accepted with a silently partial shrinker when the dependency bound is deliberately advanced.
  Date: 2026-08-10.

- Decision: Move the whole workspace to `shibuya-core ^>=0.9.0.0`, move the example's
  `shibuya-metrics` bound to `^>=0.9.0.0`, and publish the adapter as 0.14.0.0.
  Rationale: Every current `^>=0.8.0.1` bound excludes 0.9.0.0. The dependency changes an exported
  datatype and is PVP-breaking, so the adapter follows its established practice of advancing the
  second version component. Benchmark and example packages remain internal at 0.1.0.0.
  Date: 2026-08-10.

- Decision: Do not create a JSONB index automatically and do not truncate or reject detail in the
  adapter.
  Rationale: PGMQ queues are dynamic, and an automatic index policy would add write cost and schema
  ownership the adapter does not currently have. Shibuya transports detail verbatim and assigns
  applications responsibility for keeping it bounded and free of secrets, payloads, raw SQL, and
  unrestricted backend errors. The adapter repeats that guidance and measures representative and
  larger details, but does not silently change their semantics.
  Date: 2026-08-10.

- Decision: Dual writing is temporary, but this plan must not remove the legacy field.
  Rationale: Removal can recover most of the temporary payload growth only after consumers have
  migrated. Plan 6 holds that breaking work behind explicit adoption gates and a separate Mina
  intention.
  Date: 2026-08-10.

- Decision: IR-1's `targetPlan` is the canonical same-project URI
  `mori://shinzui/shibuya-pgmq-adapter/plans/5-preserve-structured-dead-letter-reasons-in-pgmq-dlq-payloads`,
  and the implementation refreshes the local Mori registration before semantic validation.
  Rationale: Mori treats `targetPlan` as a typed artifact reference, not a filesystem link, and
  validates exact plan registration. The plan body continues to use repository-relative Markdown
  links where ordinary local navigation is intended.
  Date: 2026-08-10.


## Outcomes & Retrospective

The structured dead-letter contract shipped in `shibuya-pgmq-adapter` 0.14.0.0. Production now
uses Shibuya's total public projections and writes the stable reason code and optional detail next
to the unchanged compatibility rendering. All four released reason variants, both metadata modes,
null versus empty detail, and JSON escaping have exact or property-derived coverage. A real adapter
run proved the representative application values through PostgreSQL JSONB operators while the
complete 161-example database suite kept routing, retry, trace, idempotence, shutdown, and
transactional behavior green.

The measured representative payload grew from 157 to 306 encoded bytes and from 168 to 321 JSONB
bytes. Serialization remained small relative to transport (1.17 us, 8.5 KB allocated, roughly
0.66% of the recorded single-send benchmark), and the 8 KiB case demonstrated linear copying. The
operator documentation therefore makes the real trade explicit: detail is verbatim and must be
bounded and safe; topic fan-out multiplies network, WAL, and storage; indexing remains an operator
choice; and readers retain a legacy fallback throughout the dual-write window.

The release is available at <https://hackage.haskell.org/package/shibuya-pgmq-adapter-0.14.0.0>
with published Haddocks and at
<https://github.com/shinzui/shibuya-pgmq-adapter/releases/tag/v0.14.0.0>. IR-1 is completed. The
Keiro prerequisite is now consumable, but changing that repository remains deliberately assigned
to its own workflow. Final ADR discovery again found neither `docs/adr/` nor a registered ADR
bundle, so no incidental ADR format was invented; the durable dual-write/removal boundary remains
in this plan and repository-local Plan 6.


## Context and Orientation

The repository root is the working directory for every command in this plan. It contains three
Cabal packages. `shibuya-pgmq-adapter/` is the published library and its HSpec/QuickCheck test
suite. `shibuya-pgmq-adapter-bench/` contains benchmarks and an endurance executable.
`shibuya-pgmq-example/` is the runnable example. The published adapter is currently 0.13.0.0;
the other two packages are internal 0.1.0.0 packages.

A dead-letter queue is a PGMQ queue that receives messages the handler declares permanently
unprocessable. In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`, the
`AckDeadLetter` branch enters `deadLetterTransactionally` only when `deadLetterConfig` is present.
That function calls `mkDlqPayload`, sends one message to a direct queue or topic route, and deletes
the source message in the same PostgreSQL `ReadCommitted` transaction. `AckOk`, `AckRetry`, and
`AckHalt` do not call `mkDlqPayload`. If no DLQ is configured, `AckDeadLetter` archives the source
without constructing a DLQ body. Therefore this feature adds no work to the ordinary success,
retry, halt, or archive-only paths.

`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` currently implements
`mkDlqPayload :: Pgmq.Message -> DeadLetterReason -> Bool -> Pgmq.MessageBody`. It builds a JSON
object with `original_message`, `dead_letter_reason`, and optional original-message metadata. A
private `reasonToText` matches `PoisonPill`, `InvalidPayload`, and `MaxRetriesExceeded`. That match
cannot compile exhaustively against the released application reason.

The authoritative dependency is `mori://shinzui/shibuya/packages/shibuya-core`. Hackage lists
0.9.0.0 as a normal release, and the upstream repository has annotated tag `v0.9.0.0`. Its public
`Shibuya.Core.Ack` module supplies:

```haskell
data DeadLetterReason
  = PoisonPill !Text
  | InvalidPayload !Text
  | MaxRetriesExceeded
  | ApplicationFailure !DeadLetterCode !Text

deadLetterReasonCode :: DeadLetterReason -> DeadLetterCode
deadLetterCodeText :: DeadLetterCode -> Text
deadLetterReasonDetail :: DeadLetterReason -> Maybe Text
renderDeadLetterReason :: DeadLetterReason -> Text
```

`renderDeadLetterReason` preserves the three existing strings byte-for-byte and renders an
application failure as `<code>: <detail>`. The code `keiro.router.selection.recipient_overflow`
is valid under the released grammar: at most 128 ASCII characters, at least two dot-separated
segments, each segment matching `[a-z][a-z0-9_]*`, and no reserved first segment `shibuya`.

The dependency bound appears twice in
`shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`, twice in
`shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal`, and once in
`shibuya-pgmq-example/shibuya-pgmq-example.cabal`. All five are `^>=0.8.0.1` and exclude the
released API. The example also has `shibuya-metrics ^>=0.8.0.1`; Shibuya publishes core and metrics
in the same version family, so that bound moves with core.

`shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConvertSpec.hs` asserts the three existing
renderings. `PropertySpec.hs` defines a test-only orphan `Arbitrary DeadLetterReason` instance whose
generator and shrinker enumerate only those three constructors. `ChaosSpec.hs` uses the existing
temporary PostgreSQL harness and already proves DLQ routing, trace headers, and acknowledgement
idempotence. Extend these files rather than creating a second test framework.

The public wire contract is documented twice, in
`docs/user/pgmq-dead-letter-queues.md` and `docs/pgmq-adapter/CONFIGURATION.md`. Capability evidence
lives in `docs/capabilities/dead-letter-routing.md`. The source request is
`docs/improvement-requests/preserve-application-defined-dead-letter-reasons-in-pgmq-dlq-payloads.md`,
canonically `mori://shinzui/shibuya-pgmq-adapter/okf/improvement-requests/concepts/IR-1`. It is the
adapter prerequisite for
`mori://shinzui/keiro/plans/230-make-declarative-dynamic-router-fan-out-first-class-in-keiro-dsl`.

There is no local ADR corpus today. If this remains true at implementation completion, record in
Outcomes & Retrospective that the distillation pass found no established destination rather than
inventing an incidental ADR format.


## Plan of Work

### Milestone 1 — Lock the contract and select the released dependency

First repeat the release checks in Concrete Steps. Do not choose dependency bounds from the local
checkout alone. If Hackage or upstream tags show that 0.9.0.0 was withdrawn or superseded by a
newer compatible 0.9 patch, use the newest normal 0.9 version and record the evidence. Do not cross
into a later breaking family without revising this plan.

Repair IR-1's frontmatter `origin` to
`mori://shinzui/shibuya/packages/shibuya-core`, retain the exact upstream IR URI in the prose, and
add the typed plan reference
`targetPlan: mori://shinzui/shibuya-pgmq-adapter/plans/5-preserve-structured-dead-letter-reasons-in-pgmq-dlq-payloads`.
Refresh the local Mori registration before semantic validation so the exact plan is indexed.
Tighten its Requested Change and Acceptance sections to name the three exact JSON fields, the
always-present/null detail rule, the 0.9.0.0 bound, the temporary dual-write policy, and the
deferred breaking plan. Do not mark the request complete before the release evidence exists.

Change all five `shibuya-core` constraints to `^>=0.9.0.0`, change the example's one
`shibuya-metrics` constraint to `^>=0.9.0.0`, and bump only the published adapter package from
0.13.0.0 to 0.14.0.0. Update both `CHANGELOG.md` and
`shibuya-pgmq-adapter/CHANGELOG.md` with an unreleased 0.14.0.0 entry explaining the dependency
break and additive JSON fields. At the end of this milestone, IR validation passes and Cabal
selects only Shibuya 0.9 packages; the source may still fail on the old exhaustive match until
Milestone 2 lands.

### Milestone 2 — Dual-write through total public projections

Edit `mkDlqPayload` in `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs`. Remove the local
`reasonToText` function and import the four public Shibuya projections. Compute the canonical
rendered value, stable code text, and optional detail once per payload, then add all three fields
unconditionally. Leave `original_message` and `metadataFields` unchanged.

Update `ConvertSpec.hs` with exact object assertions for all four released constructors. Prove the
three old `dead_letter_reason` strings are unchanged; prove application code/detail are verbatim;
prove max-retries detail is `Null`; and prove an empty detail is `String ""`, not `Null`. Add a
Unicode/colon detail case so JSON escaping and delimiter characters cannot corrupt the structured
value.

Update `PropertySpec.hs` to generate and shrink `ApplicationFailure` using a top-level
`DeadLetterCode` fixture created once with `mkDeadLetterCode`. Add
`{-# OPTIONS_GHC -Werror=incomplete-patterns #-}` so any future bound advance that adds a reason
constructor forces the test generator/shrinker to be reviewed. The production property must not
match constructors: for every generated reason, assert that the legacy JSON value equals
`renderDeadLetterReason reason`, the code equals
`deadLetterCodeText (deadLetterReasonCode reason)`, and detail equals the Aeson encoding of
`deadLetterReasonDetail reason`.

This milestone is complete when the whole workspace compiles against the released Hackage
packages and all non-database tests pass.

### Milestone 3 — Prove real transport, document migration, and measure cost

Add one focused PostgreSQL-backed example to `ChaosSpec.hs`. Create the representative code once,
run a handler that returns `AckDeadLetter (ApplicationFailure code detail)`, read the DLQ message,
and assert the exact three reason fields. Query the stored JSONB through PostgreSQL for
`message->>'dead_letter_reason_code'` and `message->>'dead_letter_reason_detail'` rather than only
inspecting a Haskell value, because the acceptance claim is that operators can query the real DLQ.
Also record `pg_column_size(message)` for the representative row and a legacy-shaped control row
in the same temporary database. Keep this size comparison informational: PostgreSQL version and
storage details may change the exact byte count.

Do not rewrite the transaction implementation. Run the existing DLQ routing, trace, idempotence,
retry, and atomicity coverage along with the new example. A single transaction must still contain
one DLQ send and one source delete.

Add a pure `dlq-payload-bench` benchmark component to
`shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal`, with source under
`shibuya-pgmq-adapter-bench/bench-dlq/`. It must not connect to PostgreSQL. Benchmark fully encoded
lazy bytestrings for a benchmark-only legacy-shaped control and the real dual-write
`mkDlqPayload`, using max-retries, the representative application reason, and an 8 KiB detail.
Record time and allocation. The expected shape is constant work plus linear copying in detail
length; repeated code validation inside the measured function, an additional database statement,
or nonlinear growth blocks release. Relative slowdown alone is not a blocker because the output
intentionally grows, but if typical dual-write serialization reaches five percent of the
repository's same-machine single-send benchmark, investigate and document it before release.

Update `docs/user/pgmq-dead-letter-queues.md` and
`docs/pgmq-adapter/CONFIGURATION.md` with exact examples for built-in and application reasons,
PostgreSQL query snippets, null semantics, the temporary dual-write migration, and bounded/detail
safety guidance. Update `docs/capabilities/dead-letter-routing.md` so its evidence names the unit,
property, database, and benchmark proofs. State that no index is installed; operators with large
DLQs can create an expression index under their own queue/schema policy.

### Milestone 4 — Validate, release, and close the request

Run every command in the final validation block. Inspect the source distribution to ensure its
Cabal bounds and documentation are included. Commit with Conventional Commits and both required
trailers. Publish/tag 0.14.0.0 only after Hackage dependency resolution succeeds without a local
source override.

After publication, update IR-1 to `status: completed`, add the profile-required completion
metadata and release evidence, update `docs/improvement-requests/log.md`, and rerun bundle/project
validation. Update the dependency plan in
`mori://shinzui/keiro` only through that repository's own workflow; this plan merely provides the
tagged adapter prerequisite. Finish Outcomes & Retrospective and repeat ADR discovery before
declaring this plan complete.


## Concrete Steps

Run all commands from the repository root.

Start with a clean understanding of user-owned changes and authoritative dependencies:

```bash
git status --short
mori registry search shibuya-core
mori registry show shinzui/shibuya --full
mori registry docs shinzui/shibuya
curl -fsSL https://hackage.haskell.org/package/shibuya-core/preferred.json
curl -fsSL https://hackage.haskell.org/package/shibuya-metrics/preferred.json
git ls-remote --tags https://github.com/shinzui/shibuya.git 'refs/tags/v0.9.0.0'
```

Expected registry evidence includes 0.9.0.0 as a normal version for both packages and the exact
annotated tag. Read the released `Shibuya.Core.Ack` source at the path Mori reports. Do not inspect
`/nix/store`.

Audit and update the bounds:

```bash
rg -n 'shibuya-(core|metrics)' --glob '*.cabal'
cabal build all --enable-tests --enable-benchmarks
```

After Milestone 2, Cabal succeeds and its resolved plan contains 0.9 rather than 0.8. Cabal 3.16
abbreviates package names in unit IDs, so query its explicit package fields:

```bash
jq -r '."install-plan"[]
  | select(."pkg-name" == "shibuya-core" or ."pkg-name" == "shibuya-metrics")
  | (."pkg-name" + "-" + ."pkg-version")' dist-newstyle/cache/plan.json | sort -u
```

Expected output includes:

```text
shibuya-core-0.9.0.0
shibuya-metrics-0.9.0.0
```

Run focused and full tests:

```bash
PGMQ_TEST_SKIP_DB=1 cabal test shibuya-pgmq-adapter-test --enable-tests --test-show-details=direct
cabal test shibuya-pgmq-adapter-test --enable-tests --test-show-details=direct
```

The first command has only the existing database-pending examples and zero failures. The second
starts the ephemeral PostgreSQL fixture and ends with zero failures, including the new application
reason example.

Run the pure payload benchmark and retain its short results in Surprises & Discoveries:

```bash
cabal bench dlq-payload-bench --benchmark-options='--stdev 5 --timeout 30 +RTS -T -RTS'
```

The result contains legacy and dual-write rows for the same representative reason. Record time,
allocated bytes, and encoded length; do not report the 149-byte compact-JSON calculation as JSONB
physical size.

Validate documentation and the improvement-request bundle:

```bash
mori improvement-requests validate --path .
okf validate docs/improvement-requests \
  --profile docs/improvement-requests/profile.dhall \
  --profile-enforce \
  --log-enforce
okf validate docs/capabilities \
  --profile docs/capabilities/profile.dhall \
  --profile-enforce \
  --log-enforce
mori validate
```

All commands exit zero. Then run formatting and repository gates:

```bash
nix fmt
cabal build all --enable-tests --enable-benchmarks
cabal test shibuya-pgmq-adapter-test --enable-tests --test-show-details=direct
nix flake check
git diff --check
```

Use Conventional Commits. A feature commit must carry both active identifiers:

```text
feat(dlq): preserve structured dead-letter reasons

ExecPlan: docs/plans/5-preserve-structured-dead-letter-reasons-in-pgmq-dlq-payloads.md
Intention: intention_01kzpnmd43eb5beah008ctbcds
```

Before release, build and inspect the source distribution with the repository's established
release process. After Hackage and tag verification, record the final commands and outputs in this
plan rather than leaving publication implicit.


## Validation and Acceptance

The release is accepted only when all of the following observable behaviors hold.

For `ApplicationFailure` with code `keiro.router.selection.recipient_overflow` and detail
`selected 101 recipients; configured limit is 100`, a message read from a real PGMQ DLQ contains
the exact JSON values shown in Purpose / Big Picture. PostgreSQL expressions
`message->>'dead_letter_reason_code'` and `message->>'dead_letter_reason_detail'` return the exact
code and detail. The source queue is empty after the transaction succeeds.

For `PoisonPill "x"`, `InvalidPayload "x"`, and `MaxRetriesExceeded`, the legacy field remains,
respectively, `poison_pill: x`, `invalid_payload: x`, and `max_retries_exceeded`. Their structured
codes are `poison_pill`, `invalid_payload`, and `max_retries_exceeded`. The first two details are
`"x"`; the last is JSON `null`. The properties derive those expectations from Shibuya's total
public projections rather than a production constructor match.

`includeMetadata = False` removes original-message id/time/read/header metadata but retains
`original_message` and all three reason fields. `includeMetadata = True` adds the existing metadata
without changing reason values. Empty, Unicode, quotes, backslashes, and colon-bearing details
round-trip exactly.

The database-backed suite reports zero failures for transactional atomicity, idempotent finalize,
retry behavior, and trace propagation. No new SQL statement, transaction boundary, metric label,
or trace attribute is introduced. Success/retry/halt and archive-only paths remain source-identical
apart from dependency-driven imports.

The benchmark records bounded, linear JSON encoding. For the representative ASCII values, compact
JSON grows by 149 bytes while both fields are dual-written. The measured physical JSONB delta and
serialization timing are recorded. The documentation explains that topic routing multiplies the
payload/storage cost by each matching target queue and that unbounded application detail would
scale CPU, memory, network, WAL, and storage linearly.

All five existing `shibuya-core` constraints and the benchmark component's direct constraint admit
0.9 but not 0.10; the example's `shibuya-metrics` constraint does the same. Hackage and the release
tag identify adapter 0.14.0.0, IR-1 is completed with executable evidence, and the Keiro prerequisite
can consume that tagged release.


## Idempotence and Recovery

Source, tests, docs, bounds, formatting, bundle validation, and benchmarks are safe to repeat. The
test suite owns ephemeral PostgreSQL instances and generated queue names; it must never point its
destructive cleanup at a persistent or production database. The pure benchmark has no database.

If the Hackage solver still selects 0.8, search all Cabal files for a missed bound and inspect
`dist-newstyle/cache/plan.json`; do not add `allow-newer` or a local source override. If released
0.9 source differs from this plan, stop and update every affected section and Decision Log rather
than guessing at the API.

If a test exposes a mismatch between canonical rendering and structured projections, treat the
released Shibuya functions as authoritative. Do not restore a local constructor renderer or parse
the rendered string to recover code/detail.

The dual-write change is additive and can be reverted with a normal reverting commit before
release. After consumers have observed dual-written rows, rollback to 0.13 simply stops producing
the new fields; readers must therefore follow the documented fallback during rollout. Never delete
or rewrite existing DLQ rows as part of this plan.

Publication and tagging are externally visible. Verify package metadata and the exact commit before
publishing. If publication partially succeeds, do not move or overwrite a tag; record the state and
complete the missing artifact through the normal release workflow.


## Interfaces and Dependencies

The production API remains `mkDlqPayload :: Pgmq.Message -> DeadLetterReason -> Bool ->
Pgmq.MessageBody`. Its implementation has this semantic shape:

```haskell
let rendered = renderDeadLetterReason reason
    code = deadLetterCodeText (deadLetterReasonCode reason)
    detail = deadLetterReasonDetail reason
 in Pgmq.MessageBody $
      object
        [ "original_message" .= Pgmq.unMessageBody msg.body,
          "dead_letter_reason" .= rendered,
          "dead_letter_reason_code" .= code,
          "dead_letter_reason_detail" .= detail
        ]
```

The actual function also appends the existing metadata fields when requested. It must not pattern
match on `DeadLetterReason` or use `show`.

`mori://shinzui/shibuya/packages/shibuya-core` supplies `DeadLetterReason`, opaque
`DeadLetterCode`, `mkDeadLetterCode`, `deadLetterCodeText`, `deadLetterReasonCode`,
`deadLetterReasonDetail`, and `renderDeadLetterReason` at `^>=0.9.0.0`. The application validates
codes once and the adapter only projects already-validated values. Aeson 2.2 supplies JSON objects
and the `Maybe Text` encoding (`Nothing` becomes `null`).

`mori://shinzui/pgmq-hs/packages/pgmq-core` supplies `Pgmq.Message` and `Pgmq.MessageBody`.
`mori://shinzui/pgmq-hs/packages/pgmq-hasql` encodes `MessageBody` as a PostgreSQL JSONB parameter.
No pgmq API or bound changes for this feature.

The new pure benchmark component exports no library API. It compares a benchmark-only legacy JSON
fixture with the actual `mkDlqPayload`, forces `Data.Aeson.encode` output to normal form, and reports
allocation using `tasty-bench`. It must remain runnable without `PG_CONNECTION_STRING`.

The wire contract after this plan is versioned by the adapter release rather than a new envelope
field. Readers should prefer `dead_letter_reason_code` and `dead_letter_reason_detail`, and fall back
to `dead_letter_reason` only for old rows. Plan 6 is the sole plan authorized to remove the fallback
field after its adoption gates pass.


## Revision Notes

- 2026-08-10: Recorded Milestone 1 implementation evidence, corrected IR-1's `targetPlan` from a
  filesystem path to Mori's required typed plan URI, documented the minimal agent-plans
  registration needed for validation, and replaced a Cabal-plan grep that does not work with
  abbreviated unit IDs with an exact `jq` query.
- 2026-08-10: Recorded Milestone 2's production projection integration and successful exact,
  property, compilation, and non-database validation evidence.
- 2026-08-10: Recorded Milestone 3's real PostgreSQL JSONB proof, physical/encoded size evidence,
  allocation/timing benchmark, complete database-backed regression run, and migration/operator
  documentation updates.
- 2026-08-10: Recorded the dated 0.14.0.0 release notes, final repository gates, repeated complete
  database suite, and inspected Hackage source/documentation archives ahead of publication.
- 2026-08-10: Recorded Hackage source/Haddock publication, immutable tag and GitHub release
  verification, IR-1 completion, the final ADR-distillation result, and the completed retrospective.
