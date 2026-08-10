---
id: 6
slug: remove-the-legacy-dead-letter-reason-field-after-structured-rollout
title: "Remove the legacy dead-letter reason field after structured rollout"
kind: exec-plan
created_at: 2026-08-10T20:25:53Z
intention: "intention_01kzpnmftmeex93pfzdkr5zck8"
---

# Remove the legacy dead-letter reason field after structured rollout

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This is a deliberately deferred breaking-change plan. Do not implement it as part of the
structured-reason rollout in [Plan 5](./5-preserve-structured-dead-letter-reasons-in-pgmq-dlq-payloads.md).
It becomes actionable only after an adapter release has dual-written the legacy rendered reason
and the structured code/detail long enough for known consumers to migrate, and after the
maintainer records a go/no-go rollout decision in this plan.

After the breaking release, new PGMQ dead-letter queue (DLQ) rows no longer duplicate the reason
code and detail inside `dead_letter_reason`. They contain only the structured contract:

```json
{
  "dead_letter_reason_code": "keiro.router.selection.recipient_overflow",
  "dead_letter_reason_detail": "selected 101 recipients; configured limit is 100"
}
```

For a reason without detail, `dead_letter_reason_detail` remains present as JSON `null`. Removing
the compatibility member recovers about 115 compact-JSON bytes for the representative reason.
The structured-only representation is still about 34 bytes larger than the original one-string
representation because it uses two descriptive keys, but it preserves the machine-facing value
without parsing human text.

The change affects only new DLQ writes. Historical rows retain whichever schema they were written
with, so operators can observe legacy-only, dual-written, and structured-only rows in one queue
until retention removes older data. Documentation and first-party readers must therefore use a
mixed-history query during that period. A user can verify the completed change by sending a new
dead-letter message, observing that `dead_letter_reason` is absent while code/detail remain exact,
and comparing its encoded and PostgreSQL JSONB sizes with a dual-written control.


## Progress

- [ ] G0 — Rollout gate: confirm Plan 5 is completed and released, inventory known dependents,
  prove their structured-field adoption, complete the deprecation window, and record explicit
  maintainer approval to begin this breaking change.
- [ ] M1 — Capture the released dual-write baseline, choose the next PVP-breaking adapter version,
  and publish migration notes before changing output.
- [ ] M2 — Stop writing `dead_letter_reason`, update exact unit/property/database coverage, and
  retain structured code/detail semantics for every reason.
- [ ] M3 — Compare serialization and JSONB size with the dual-write release, update capability and
  operator documentation for mixed historical rows, and run all repository gates.
- [ ] M4 — Publish/tag the breaking release, verify downstream resolution, and complete the ADR
  distillation and retrospective.


## Surprises & Discoveries

- At authoring time, `mori registry dependents shinzui/shibuya-pgmq-adapter --packages` returned no
  registered package dependents, but direct inspection through Mori found
  `mori://shinzui/keiro/packages/keiro-pgmq` and Keiro's example package bounded to adapter 0.13.
  Registry reverse-dependency metadata is therefore useful but not sufficient evidence that all
  known first-party consumers migrated. Gate G0 requires both Mori discovery and inspection of
  the manifests/tests in every discovered or already-known consumer project.
- Removing a field changes only future rows. PGMQ does not rewrite queued JSONB when an adapter is
  upgraded, and this repository does not own every queue's retention policy. A mixed-history read
  contract is mandatory even after all code consumers adopt the structured fields.
- For the representative 41-byte code and 48-byte detail, the compact JSON member
  `dead_letter_reason` occupies 114 bytes by itself and 115 bytes when its separating comma is
  counted. Dual writing adds 149 bytes over the old one-field object. Removing the legacy member
  recovers about 115 of those bytes, leaving structured-only output about 34 compact-JSON bytes
  larger than the pre-structured format. PostgreSQL physical size still requires measurement.
- No local `docs/adr/` directory or ADR bundle existed during authoring. Repeat discovery at G0 and
  again before completion; do not invent an ADR format only because this plan anticipates a durable
  wire break.


## Decision Log

- Decision: This plan is blocked until Gate G0 is affirmatively completed; creating the plan and
  Mina intention does not authorize implementation.
  Rationale: Removing `dead_letter_reason` breaks deployed JSON readers. Elapsed time or the
  existence of structured fields is not proof of adoption. The maintainer explicitly requested
  that removal wait for the breaking-change rollout.
  Date: 2026-08-10.

- Decision: The breaking release removes only `dead_letter_reason`; it preserves the exact names,
  types, null semantics, and meaning of `dead_letter_reason_code` and
  `dead_letter_reason_detail`.
  Rationale: Renaming or nesting structured fields during legacy removal would force consumers
  through a second migration and invalidate the adoption evidence used to open the gate.
  Date: 2026-08-10.

- Decision: If Plan 5 publishes adapter 0.14.0.0 and no intervening breaking family exists, this
  release is 0.15.0.0. Otherwise choose the next unused PVP-breaking second component at G0 and
  revise every version reference in this plan before editing code.
  Rationale: The JSON contract is public behavior even though the Haskell function signature does
  not change. Existing repository releases advance the second version component for breaking
  compatibility changes.
  Date: 2026-08-10.

- Decision: Do not backfill, delete, or rewrite historical DLQ rows as part of this release.
  Rationale: Queue ownership, retention, and operational risk belong to applications. Mixed-history
  queries are safe and reversible; a generic mutation over dynamically named PGMQ tables is not.
  Date: 2026-08-10.

- Decision: Open Gate G0 from adoption evidence, not from an arbitrary calendar interval alone.
  Rationale: A full released family plus migration notices gives external consumers a usable
  window, but known first-party consumers must additionally show code/tests that read the
  structured fields. Public consumers cannot be exhaustively enumerated, so the breaking release
  must still carry prominent migration notes and a PVP version break.
  Date: 2026-08-10.

- Decision: Keep the code/detail fields top-level and do not shorten their names to recover more
  bytes.
  Rationale: The byte-saving goal is removal of temporary duplication, not sacrificing a readable,
  already-adopted contract for marginal key savings.
  Date: 2026-08-10.


## Outcomes & Retrospective

Deferred at authoring time. Gate G0 has not been evaluated and no removal is authorized.


## Context and Orientation

This repository's published library is in `shibuya-pgmq-adapter/`; tests are under
`shibuya-pgmq-adapter/test/`; the pure payload benchmark introduced by Plan 5 is under
`shibuya-pgmq-adapter-bench/`; and user/capability documentation is under `docs/`.

Plan 5 is the prerequisite and source of the dual-write contract. Its intended 0.14.0.0 release
changes `mkDlqPayload` in `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` to emit:

```json
{
  "original_message": {"example": true},
  "dead_letter_reason": "application.code: detail",
  "dead_letter_reason_code": "application.code",
  "dead_letter_reason_detail": "detail"
}
```

The legacy field is a canonical compatibility rendering owned by
`mori://shinzui/shibuya/packages/shibuya-core`; the two structured fields are the adapter's JSON
contract. `mkDlqPayload` is called only by the configured-DLQ `AckDeadLetter` branch in
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`. Success, retry, halt, and
archive-without-DLQ paths do not construct this payload. The send and source delete run in one
PostgreSQL transaction and must remain unchanged.

The source improvement request is
`mori://shinzui/shibuya-pgmq-adapter/okf/improvement-requests/concepts/IR-1`. Plan 5 completes that
request because it delivers end-to-end structured preservation. This later optimization does not
reopen or replace IR-1; it removes the compatibility field after the migration promised by that
request has completed.

The first known adopter is
`mori://shinzui/keiro/packages/keiro-pgmq`, coordinated by
`mori://shinzui/keiro/plans/230-make-declarative-dynamic-router-fan-out-first-class-in-keiro-dsl`.
At authoring time Keiro still requires adapter `>=0.13 && <0.14`, so it is not adoption evidence
yet. Gate G0 requires a released-compatible bound and tests that query the structured fields.
`mori registry dependents` must be rerun because project registrations and consumer versions can
change.

PGMQ stores each queue in a PostgreSQL table whose `message` column is JSONB. An adapter upgrade
does not alter rows already in that table. During retention overlap, a consumer can use this
read-only compatibility projection:

```sql
SELECT
  COALESCE(
    message ->> 'dead_letter_reason_code',
    split_part(message ->> 'dead_letter_reason', ':', 1)
  ) AS reason_code,
  CASE
    WHEN message ? 'dead_letter_reason_detail'
      THEN message ->> 'dead_letter_reason_detail'
    WHEN position(': ' IN (message ->> 'dead_letter_reason')) > 0
      THEN substring(
        (message ->> 'dead_letter_reason')
        FROM position(': ' IN (message ->> 'dead_letter_reason')) + 2
      )
    ELSE NULL
  END AS reason_detail
FROM pgmq.q_example_dlq;
```

The fallback splits only on the first canonical `: ` delimiter. Historical adapter versions could
write only the built-in reasons, while application reasons first become available in the
dual-write release, so structured data is available for every application reason. This query is
documentation, not an adapter-side parser or a database migration. Operators must substitute their
validated queue table and apply their own access controls.

There is no local ADR corpus at authoring time. The future implementer must repeat the conditional
ADR workflow and summarize any relevant decision locally if a corpus has appeared.


## Plan of Work

### Gate G0 — Prove the rollout is ready for a wire break

Do not edit production code before completing this gate. Verify that Plan 5 is complete, its
adapter release is present on Hackage and under an immutable upstream tag, IR-1 is completed, and
the dual-write documentation has shipped. At least one full adapter release family must have
carried both schemas; a release that was tagged but never adopted is not sufficient.

Run Mori's reverse-dependency lookup. For every registered package/project, inspect current
dependency bounds and DLQ reader code at the source path Mori reports. Also inspect already-known
first-party consumers even if reverse metadata omits them. A consumer counts as adopted only when
its released or deployment-target code prefers `dead_letter_reason_code` and
`dead_letter_reason_detail`, tolerates old rows, and has executable coverage. Merely widening a
Cabal bound does not count.

Record the inventory in Surprises & Discoveries with canonical project/package URIs, versions,
test evidence, and any remaining owner/action. External public users cannot be enumerated, so also
confirm the 0.14 release notes marked the legacy field deprecated and prepare a prominent breaking
migration note. The maintainer must add a dated Decision Log entry saying Gate G0 is open. If any
known consumer is not ready, leave G0 unchecked and stop.

### Milestone 1 — Capture the dual-write baseline and announce the break

Re-verify current Hackage releases and upstream tags. If Plan 5 was not released as 0.14.0.0 or an
intervening release exists, revise this plan's target version to the next unused PVP-breaking
family. Do not change Shibuya bounds unless an independently required API migration is planned and
documented; this plan is about the JSON field removal.

Run the pure payload benchmark from the released dual-write tag in a detached temporary worktree,
then run it on the pre-removal current tree with identical compiler and RTS options. Store short
CSV/output evidence outside the repository until results are summarized here. Record encoded byte
length and PostgreSQL `pg_column_size(message)` for the representative application reason.

Add unreleased breaking entries to both changelogs and update the user guide before code removal so
the migration contract is reviewable independently. The notes must say that new rows omit
`dead_letter_reason`, old rows remain untouched, code/detail fields are unchanged, and consumers
must support mixed history.

### Milestone 2 — Remove only the legacy write

Edit `mkDlqPayload` in `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` to remove the
`dead_letter_reason` pair. Remove the `renderDeadLetterReason` import only if no remaining code in
that module uses it. Keep upstream code/detail projections, `original_message`, optional metadata,
and all transaction code unchanged.

Update `ConvertSpec.hs` and `PropertySpec.hs` so every reason proves the legacy key is absent and
the structured values remain identical to Plan 5. Preserve the incomplete-pattern warning gate in
the test generator/shrinker. Keep empty text distinct from null and retain Unicode/escaping cases.

Update the PostgreSQL-backed `ChaosSpec.hs` application-reason example. It must query the real DLQ
and prove that `message ? 'dead_letter_reason'` is false, code/detail are exact, the source was
deleted transactionally, and repeated successful finalize still creates one DLQ row. Existing
trace, retry, atomicity, and topic/direct behavior remains green.

### Milestone 3 — Prove byte recovery and document mixed history

Run the same pure benchmark and JSONB size probe used for the dual-write baseline. For the
representative compact JSON, removal should recover about 115 bytes. Record actual encoded and
physical deltas; investigate if output grows, serialization becomes nonlinear, or a database
statement changes. The normal processing path remains unaffected because `mkDlqPayload` stays
inside configured dead-lettering.

Update `docs/user/pgmq-dead-letter-queues.md`, `docs/pgmq-adapter/CONFIGURATION.md`, and
`docs/capabilities/dead-letter-routing.md`. Current-format examples show only code/detail. A
migration section retains the mixed-history SQL above, identifies the last dual-write and first
structured-only releases, and states that no automatic index/backfill/deletion occurs. Capability
evidence points to exact absence/preservation tests and benchmark results.

Run every validation command. If a first-party consumer repository is part of the coordinated
rollout, update it only under its own plan/intention and commit history; do not make cross-repository
edits from this plan silently.

### Milestone 4 — Publish the breaking release and close out

Build and inspect the source distribution, commit with the Plan 6 and Mina intention trailers, and
publish/tag only the reviewed commit. Verify Hackage metadata and tag independently. Re-run at
least the primary first-party consumer's dependency resolution and structured DLQ test against the
published adapter rather than a local path.

Complete Outcomes & Retrospective with byte/timing recovery, consumer evidence, and any external
migration limitation. Repeat ADR discovery and distill the durable wire-version decision before
marking the plan complete.


## Concrete Steps

Run repository commands from the repository root. Gate G0 starts with read-only checks:

```bash
git status --short
curl -fsSL https://hackage.haskell.org/package/shibuya-pgmq-adapter/preferred.json
git ls-remote --tags https://github.com/shinzui/shibuya-pgmq-adapter.git
mori path mori://shinzui/shibuya-pgmq-adapter/okf/improvement-requests/concepts/IR-1
mori registry dependents shinzui/shibuya-pgmq-adapter --packages
mori registry show shinzui/keiro --full
```

Expected evidence before proceeding includes a normal dual-write adapter release, its immutable
tag, completed IR-1, and a nonempty written inventory even if Mori's reverse-dependency output is
empty. Resolve each consumer with Mori and inspect only its reported project path. For the known
Keiro consumer, confirm its bounds and structured-field tests; do not rely on the authoring-time
0.13 result.

Capture a baseline from the exact dual-write tag without switching the active checkout:

```bash
baseline_root=$(mktemp -d /tmp/shibuya-pgmq-dlq-removal.XXXXXX)
git worktree add --detach "$baseline_root/dual-write" v0.14.0.0
(
  cd "$baseline_root/dual-write"
  cabal bench dlq-payload-bench \
    --benchmark-options="--csv $baseline_root/dual-write.csv --stdev 5 --timeout 30 +RTS -T -RTS"
)
```

If the actual dual-write tag is not `v0.14.0.0`, revise the plan first and use the verified tag.
The temporary worktree is read-only baseline evidence. Remove it only after resolving the exact
path with `git worktree list`; do not use a broad glob.

After implementation, build and test the active tree:

```bash
cabal build all --enable-tests --enable-benchmarks
PGMQ_TEST_SKIP_DB=1 cabal test shibuya-pgmq-adapter-test \
  --enable-tests \
  --test-show-details=direct
cabal test shibuya-pgmq-adapter-test \
  --enable-tests \
  --test-show-details=direct
cabal bench dlq-payload-bench \
  --benchmark-options="--baseline $baseline_root/dual-write.csv --stdev 5 --timeout 30 +RTS -T -RTS"
```

The test transcript ends with zero failures. The benchmark reports smaller structured-only output;
summarize the measurements rather than committing machine-specific CSV files.

Validate docs and repository state:

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
nix fmt
nix flake check
git diff --check
```

All commands exit zero. Use a Conventional Commit with an explicit breaking marker and both active
trailers:

```text
feat(dlq)!: remove the legacy dead-letter reason field

BREAKING CHANGE: New PGMQ DLQ payloads no longer include dead_letter_reason;
read dead_letter_reason_code and dead_letter_reason_detail instead.

ExecPlan: docs/plans/6-remove-the-legacy-dead-letter-reason-field-after-structured-rollout.md
Intention: intention_01kzpnmftmeex93pfzdkr5zck8
```

After publication, resolve at least the primary first-party consumer against Hackage and run its
structured DLQ acceptance test. Record exact package versions and results in this plan.


## Validation and Acceptance

Gate G0 is acceptance-critical. The plan cannot progress merely because the code change is small.
Plan 5 and IR-1 are complete under a tagged, published dual-write release. The inventory names all
known registered and first-party consumers, and every known deployed/target consumer prefers the
structured fields, handles old rows, and has executable evidence. A dated maintainer Decision Log
entry explicitly opens the gate and selects the breaking version.

After implementation, a new real PGMQ DLQ row for the representative application reason satisfies:

```sql
SELECT
  message ? 'dead_letter_reason' AS has_legacy,
  message ->> 'dead_letter_reason_code' AS reason_code,
  message ->> 'dead_letter_reason_detail' AS reason_detail
FROM pgmq.q_example_dlq;
```

The observed result is equivalent to:

```text
has_legacy | reason_code                                      | reason_detail
false      | keiro.router.selection.recipient_overflow        | selected 101 recipients; configured limit is 100
```

Every built-in and application reason preserves the structured values defined by Shibuya's public
projections. Max-retries detail remains JSON null; empty detail remains an empty string. Both
`includeMetadata` modes omit only or include original metadata as before and never restore the
legacy field.

Existing PostgreSQL-backed tests report zero failures for one-transaction send/delete,
idempotence, retries, trace propagation, and direct/topic routing. New rows omit the legacy key;
old rows are neither rewritten nor deleted. The user guide's mixed-history query returns stable
code/detail for legacy-only, dual-write, and structured-only fixtures.

The benchmark and database size probe record the actual savings. The representative compact JSON
recovers approximately 115 bytes, with structured-only output approximately 34 bytes larger than
the original legacy-only shape. Deviations caused by JSON escaping or JSONB layout are explained.
No new SQL, index, metric label, trace attribute, or work on non-DLQ processing paths is introduced.

The published package and immutable tag use the selected PVP-breaking version. Hackage-based
consumer verification passes without local source overrides. Changelogs name the last dual-write
and first structured-only versions and give the migration query.


## Idempotence and Recovery

Gate checks, searches, builds, tests, benchmarks, validation, and formatting are repeatable. The
PostgreSQL test harness owns ephemeral databases; it must not be aimed at a persistent queue.
The mixed-history SQL is read-only. This plan never authorizes production row mutation.

The temporary baseline worktree is safe because it is detached and lives beneath an exact
`mktemp` directory. If setup fails, inspect `git worktree list`, remove only the exact registered
worktree with `git worktree remove <resolved-path>`, then remove the exact empty temporary directory.
Never delete `/tmp`, the repository root, a glob, or an unresolved variable.

Before publication, the source edit can be reverted with a normal patch or reverting commit while
leaving unrelated work intact. After publication, rolling back the adapter causes new rows to
dual-write again; it does not restore the field on structured-only rows already queued. Consumers
must therefore retain mixed-history support through the queue's maximum retention horizon even if
the deployment is rolled back.

If a known consumer fails Gate G0 or Hackage verification, stop without changing production code.
If a test finds that structured values changed, restore the Plan 5 contract; do not compensate by
parsing the removed renderer. If the benchmark shows unexpected growth or another DB statement,
investigate before release rather than weakening acceptance.

Publication and tags are irreversible coordination points. Never overwrite or move a published
tag. A partial release is recorded and completed through the repository's normal release process.


## Interfaces and Dependencies

The Haskell API remains:

```haskell
mkDlqPayload ::
  Pgmq.Message ->
  DeadLetterReason ->
  Bool ->
  Pgmq.MessageBody
```

Only the JSON object changes. Its reason portion has this semantic shape:

```haskell
let code = deadLetterCodeText (deadLetterReasonCode reason)
    detail = deadLetterReasonDetail reason
 in [ "dead_letter_reason_code" .= code,
      "dead_letter_reason_detail" .= detail
    ]
```

There is no `dead_letter_reason` pair and no need to call `renderDeadLetterReason` in production.
`mori://shinzui/shibuya/packages/shibuya-core` remains semantic authority for code/detail.
`mori://shinzui/pgmq-hs/packages/pgmq-core` and
`mori://shinzui/pgmq-hs/packages/pgmq-hasql` continue carrying the Aeson value to PostgreSQL JSONB.
No dependency API change is required solely for removal, but all current releases and bounds must
be re-verified at G0 because this plan is intentionally future work.

The structured JSON contract remains:

```text
dead_letter_reason_code   JSON string, always present
dead_letter_reason_detail JSON string or null, always present
```

Readers must support historical schemas for at least their queue retention horizon. They may use
the documented SQL projection or equivalent typed logic, but the adapter does not expose a DLQ
decoder and does not mutate existing rows.

The focused `dlq-payload-bench` from Plan 5 is the performance interface. It must retain stable
benchmark names for dual-write baseline comparison and add structured-only names if necessary.
Benchmark fixtures may construct the old JSON shapes for comparison; production code must not.
