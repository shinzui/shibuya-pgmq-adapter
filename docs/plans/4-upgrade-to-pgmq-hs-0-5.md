---
id: 4
slug: upgrade-to-pgmq-hs-0-5
title: "Upgrade to pgmq-hs 0.5"
kind: exec-plan
created_at: 2026-08-09T13:14:21Z
intention: "intention_01kzk9w7sqeg8tkwpm4z3xaw94"
---

# Upgrade to pgmq-hs 0.5

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, `shibuya-pgmq-adapter` resolves and builds against the released
`pgmq-hs` 0.5 package family instead of the 0.4 family. Users gain the 0.5 correctness
fixes for queue-name validation, visibility-timeout races, transient PostgreSQL error
classification, SQL `NULL` handling, and notification recovery while retaining the
adapter's existing public API. The package requirement and migration guidance will make
the stricter queue-name rule visible before an operator deploys the upgrade.

The most important adapter-owned behavior is lease extension. In `pgmq-hs` 0.5,
`setVisibilityTimeoutAt` returns `Nothing` when the message was deleted, archived, or
popped before the lease-extension statement reached it. The adapter must treat that
defined race as a benign no-op, leave its last known visibility deadline unchanged, and
continue without the `UnexpectedRowCountStatementError` that 0.4 produced. A new
database-backed regression test will read and delete a message, invoke the adapter's
lease extension, and finish successfully. A second regression test will show that the
adapter's re-exported `parseQueueName` rejects uppercase and empty names under 0.5.

The upgrade is observable by building every library, example, test, benchmark, and
endurance component; inspecting Cabal's resolved plan to see only `pgmq-*` 0.5 packages;
and running the PostgreSQL-backed adapter suite with zero failures. The pre-change
baseline recorded during plan research was a successful whole-workspace build and 152
passing examples. The planned regression examples should increase that count while
keeping failures at zero.


## Progress

- [x] (2026-08-09T13:41:14Z) M1. Re-verified Hackage and the upstream tags at 0.5.0.0, updated all 23 workspace bounds to `^>=0.5`, and bumped the adapter package to 0.13.0.0 while leaving the benchmark and example packages at 0.1.0.0.
- [x] (2026-08-09T13:46:12Z) M2. Adapted lease extension to leave its confirmed deadline unchanged for `Nothing`, added the lost-row and public parser regressions, passed the PostgreSQL-backed suite with 154 examples and zero failures, and built every workspace component with tests and benchmarks enabled.
- [x] (2026-08-09T13:46:44Z) M3. Updated current requirements and the example's component-pattern wording, documented the 0.5 queue-name rule and pre-rollout remediation gate, aligned lease documentation with the benign lost-row race, and added 0.13.0.0 entries to both changelogs; the stale-0.4 audit found only deliberate historical references.
- [ ] M4. Format, build every component, run the complete database-backed suite and repository checks, inspect the resolved dependency plan, and commit the finished upgrade.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Target the published `pgmq-hs` 0.5.0.0 release through `^>=0.5` bounds in every component.
  Rationale: On 2026-08-09, Hackage's preferred-version records for `pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, `pgmq-migration`, and `pgmq-config` all listed 0.5.0.0 as the newest normal version, and the authoritative upstream tag list ended at `v0.5.0.0`. `^>=0.5` means `>=0.5 && <0.6`, admitting compatible 0.5 patch releases without silently crossing the next breaking family. The implementation must repeat both checks because “latest” is time-sensitive; if a newer family exists then, revise this plan before editing bounds.
  Date: 2026-08-09

- Decision: Use Hackage for dependency resolution and Mori only to locate and inspect the upstream source.
  Rationale: All required 0.5 packages are already published. A `source-repository-package` or machine-local path override would hide whether a normal downstream user can solve the released package set. The upstream checkout remains the source of API and behavior evidence, resolved through `mori://shinzui/pgmq-hs` rather than a hard-coded cross-repository path.
  Date: 2026-08-09

- Decision: Treat `setVisibilityTimeoutAt` returning `Nothing` as a successful no-op and update `lastVtRef` only for `Just message`.
  Rationale: The 0.5 result distinguishes a normal lost race from database failure: `Nothing` means the row no longer exists because it was deleted, archived, or popped. The handler cannot extend a nonexistent row, and inventing an adapter-specific database error would erase the distinction the new API creates. Leaving the previous in-memory deadline untouched also avoids recording a deadline that PostgreSQL did not accept. This follows the consumer adaptation recorded by the intended upstream artifact URI `mori://shinzui/pgmq-hs/plans/12-expose-grouped-reads-on-the-umbrella-api-and-release-0-5-0-0`; current Mori releases do not yet resolve that plan kind, but the URI is canonical and the source is available under the upstream checkout.
  Date: 2026-08-09

- Decision: Do not change the `AckRetry` or `AckHalt` branches beyond recompiling them against 0.5.
  Rationale: Both branches already discard `changeVisibilityTimeout` with `void`, so changing its result from `Message` to `Maybe Message` preserves their behavior and type-checks. `mkLease` is the only adapter call site that reads a returned message and therefore the only source adaptation required.
  Date: 2026-08-09

- Decision: Document and test the stricter queue-name boundary, but do not copy the upstream mixed-case remediation program into this repository.
  Rationale: The public contract is small and belongs here: names must match `[a-z0-9_]{1,47}`, and deployed databases must be checked for mixed-case `pgmq.meta` rows before rollout. The transaction that safely merges aliases, preserves topic bindings and notification throttles, and deletes physical-table orphans is owned by `mori://shinzui/pgmq-hs`; duplicating that long SQL program here would create two migration sources that can drift. This plan embeds the detection query and the operational outcome needed to write accurate guidance, while the user-facing note points to the upstream canonical project and its `docs/design/016-queue-name-validation.md` path because an artifact-level URI for that design document is pending.
  Date: 2026-08-09

- Decision: Bump only the published adapter package from 0.12.0.0 to 0.13.0.0; keep the benchmark and example packages at 0.1.0.0.
  Rationale: Requiring a new breaking dependency family and tightening the re-exported `parseQueueName` behavior is a breaking compatibility change even though the adapter's own function signatures remain stable. Previous breaking dependency-family upgrades advanced the adapter's second version component. The benchmark and example packages are in-workspace validation consumers rather than the published adapter API, and their existing versions do not track adapter releases.
  Date: 2026-08-09

- Decision: Keep `pgmq-config` out of this workspace's dependency list.
  Rationale: `pgmq-hs` releases five library packages in lockstep, but no component in this repository imports or declares `pgmq-config`. Adding an unused dependency would widen the build and public dependency surface without enabling behavior. The 0.5 bounds apply only to the four packages already consumed: `pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, and `pgmq-migration`.
  Date: 2026-08-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This is a Cabal workspace with three local packages, listed in `cabal.project`.
`shibuya-pgmq-adapter/` is the published adapter library and its HSpec test suite.
`shibuya-pgmq-adapter-bench/` contains a `tasty-bench` benchmark and a long-running
endurance executable. `shibuya-pgmq-example/` contains a reusable example library and two
executables, a consumer and a simulator. All three packages must resolve one coherent
`pgmq-hs` family because Cabal cannot install 0.4 and 0.5 instances of the same package
into one component graph when the declared bounds exclude one another.

`pgmq-hs` is the Haskell client for PostgreSQL Message Queue (PGMQ), a queue implemented
inside PostgreSQL. This repository consumes four packages from that project.
`pgmq-core` provides shared types such as `Message`, `MessageId`, and the validated
`QueueName`. `pgmq-hasql` provides direct database sessions and statements.
`pgmq-effectful` lifts those operations into the Effectful effect system and classifies
runtime errors for retries. `pgmq-migration` provides a `pg-migrate` component that
installs and upgrades the PGMQ schema. The project-qualified dependency URI is
`mori://shinzui/pgmq-hs`, and its package URIs are, for example,
`mori://shinzui/pgmq-hs/packages/pgmq-core` and
`mori://shinzui/pgmq-hs/packages/pgmq-effectful`.

Every current pgmq bound is `^>=0.4`. There are 23 declarations spread across
`shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`,
`shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal`, and
`shibuya-pgmq-example/shibuya-pgmq-example.cabal`. The adapter package itself is version
0.12.0.0. `cabal.project` contains only the three local packages and an unrelated
`allow-newer` group for `proto-lens`; it has no source override for pgmq. After a baseline
build, `dist-newstyle/cache/plan.json` reports:

```text
pgmq-core-0.4.0.1
pgmq-effectful-0.4.0.1
pgmq-hasql-0.4.0.1
pgmq-migration-0.4.0.1
```

The one source-level incompatibility is in
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`, function `mkLease`.
A Shibuya `Lease` is the optional capability a handler uses to keep a message invisible
while long-running work continues. `mkLease` stores the most recently confirmed absolute
visibility deadline in `lastVtRef :: IORef UTCTime`, computes a monotone target, and calls
`Pgmq.Effectful.Effect.setVisibilityTimeoutAt`. Under 0.4 that function returned `Message`,
so the code unconditionally reads `updated.visibilityTime`. Under 0.5 its signature is:

```haskell
setVisibilityTimeoutAt ::
  (Pgmq :> es) =>
  VisibilityTimeoutAtQuery ->
  Eff es (Maybe Message)
```

`Just message` confirms the row was updated and supplies the database's resulting
deadline. `Nothing` means the target row had already disappeared and is not a database
error. The sibling `changeVisibilityTimeout` operation has the same new result shape, but
the adapter calls it only in the `AckRetry` and `AckHalt` branches and already discards the
result with `void`.

Version 0.5 also changes the `QueueName` boundary. `parseQueueName` and the `FromJSON`
instance now accept only a non-empty name of at most 47 characters containing lowercase
ASCII letters, digits, and underscore. Uppercase was accepted in 0.4, even though PGMQ
lowercases physical table names while retaining the original case in metadata; that could
make two logical names alias one physical queue. The repository's source and test queue
names are already lowercase. One documentation example in
`docs/pgmq-adapter/CONFIGURATION.md` incorrectly uses `my-queue`, which even 0.4 rejected;
replace it with `my_queue` while documenting the complete 0.5 rule.

Before rollout, an operator can detect mixed-case metadata with this read-only query. It
does not mutate a database and is included here so the implementation can write a precise
upgrade note:

```sql
SELECT queue_name, lower(queue_name) AS canonical_name
FROM pgmq.meta
WHERE queue_name <> lower(queue_name);
```

An empty result needs no queue-name remediation. A non-empty result must be backed up and
remediated before deploying the new packages. A simple `UPDATE` or `DELETE` is unsafe:
topic bindings and notification throttles reference `pgmq.meta` without `ON UPDATE` and
with `ON DELETE CASCADE`, and differently-cased rows can alias one physical table. The
canonical upstream remediation creates or reuses the lowercase parent, repoints child
rows, preserves existing canonical throttle state, removes duplicates, and deletes an
orphan rather than inventing metadata for a missing table. Resolve the authoritative
source with `mori path mori://shinzui/pgmq-hs` and read
`docs/design/016-queue-name-validation.md`; cite it in durable prose as the canonical
project URI plus that project-relative path until its artifact-level URI is registered.

The `pgmq-migration` public API introduced in 0.4 is unchanged in 0.5, so
`shibuya-pgmq-adapter/test/TmpPostgres.hs`,
`shibuya-pgmq-adapter-bench/bench/BenchSetup.hs`,
`shibuya-pgmq-adapter-bench/app/Endurance.hs`, and
`shibuya-pgmq-example/src/Example/Database.hs` require no source edits. The existing
`Migration.pgmqMigrations` component will include 0.5's notification crash-safety
migration. The adapter owns neither that SQL nor the new low-level `pgmq-config` API.

The repository root is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`. During plan research,
the following baseline commands succeeded from that directory:

```bash
cabal build all --enable-tests --enable-benchmarks
cabal test shibuya-pgmq-adapter-test --enable-tests --test-show-details=direct
```

The test transcript ended with:

```text
Finished in 41.5087 seconds
152 examples, 0 failures
Test suite shibuya-pgmq-adapter-test: PASS
```

Do not use bare `cabal test all` as the validation command in this checkout. The solver
reported `Cabal-7043` because test suites were not enabled. Pass `--enable-tests` or name
the suite exactly as above.


## Plan of Work

### Milestone 1 — Move the entire workspace onto the released 0.5 family

First repeat the dependency-release checks in Concrete Steps. The local Mori corpus was at
upstream commit `9ee9a2f`, one documentation commit after the `v0.5.0.0` release, while
Hackage and the upstream tag list both identified 0.5.0.0 as latest during authoring. If
either authoritative source now names a version newer than 0.5, stop and revise the title,
bounds, compatibility analysis, and changelog scope; do not mechanically execute a stale
“latest” plan.

In all three Cabal files, change every existing `pgmq-core ^>=0.4`,
`pgmq-hasql ^>=0.4`, `pgmq-effectful ^>=0.4`, and
`pgmq-migration ^>=0.4` declaration to `^>=0.5`. Do not add `pgmq-config`, change
`pg-migrate ^>=1.1`, or add a source override to `cabal.project`. In
`shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`, change the package version from
0.12.0.0 to 0.13.0.0. The benchmark and example package versions stay 0.1.0.0.

Run the bound searches shown in Concrete Steps. There must be no `^>=0.4` pgmq declaration
and there must be 23 `^>=0.5` declarations. A build at this exact point is expected to
expose the `Maybe Message` error at `updated.visibilityTime`; that is evidence the resolver
selected the intended API, not a reason to weaken a bound. Milestone 2 immediately makes
the workspace green. The durable milestone acceptance is the combination of all 23 bounds
at 0.5, adapter version 0.13.0.0, and the successful targeted build after Milestone 2.

### Milestone 2 — Preserve lease behavior across a raced-away message

Edit `mkLease` in
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`. Keep the retry wrapper and
absolute target calculation unchanged. After `updated <- retryingTransient ...
setVisibilityTimeoutAt ...`, pattern-match on `updated`: do nothing for `Nothing`; for
`Just updatedMessage`, write `updatedMessage.visibilityTime` to `lastVtRef`. Do not write
the computed target directly, because only the value returned by PostgreSQL confirms a
successful extension. Do not retry `Nothing`, because it is a successful SQL result and
cannot become `Just` by repeating a request against a row that has disappeared.

Add a database-backed example under the visibility-timeout group in
`shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/IntegrationSpec.hs`. Use the existing
`TestFixture`, `runAdapterIO`, and temporary PostgreSQL harness. Send and read one message,
construct a lease with `mkLease (defaultConfig queueName) msg`, delete that message through
the PGMQ effect, then call `lease.leaseExtend 30`. Assert the effect action returns normally
and that a follow-up queue read is empty. Under 0.4 the extension after deletion raises a
single-row decoder error; under the adapted 0.5 path it returns `Nothing` and the test
passes. Import `mkLease` and `Shibuya.Core.Lease (Lease (..))` as needed; no production
module export change is required because `mkLease` is already exported from the internal
module.

Add one focused public-boundary example to
`shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConfigSpec.hs`. The test should assert that
`parseQueueName "orders"` succeeds while `parseQueueName "Orders"` and
`parseQueueName ""` both fail. This test deliberately exercises the adapter's re-exported
dependency contract, so import `parseQueueName` from `Shibuya.Adapter.Pgmq` rather than
directly from `Pgmq.Types`; retain the direct `parseRoutingKey` import. The example would
fail against 0.4 because uppercase and empty inputs were accepted there.

Run the named test suite. The pre-change suite had 152 examples; two new HSpec `it`
examples should normally yield 154 examples, zero failures. If concurrent work has added or
removed tests, record the new count in Progress instead of forcing 154, but zero failures
and both new example names are non-negotiable. Then build every component with tests and
benchmarks enabled. This milestone ends with a coherent, compiling 0.5 workspace and live
PostgreSQL proof of the lost-race behavior.

### Milestone 3 — Publish accurate compatibility and operational guidance

Update the current-version requirements in `docs/pgmq-adapter/README.md` and
`docs/user/pgmq-getting-started.md` from the `pgmq-*` 0.4 family to 0.5. The
`pgmq-migration` component pattern was introduced in 0.4 and remains the same; where
`shibuya-pgmq-example/README.md` calls it the “0.4 pattern,” say “0.4 and later component
pattern” so the historical origin and current validity are both clear. Do not rewrite true
historical references to the old 0.3 ledger or to PGMQ server version 1.11.0.

In `docs/pgmq-adapter/CONFIGURATION.md`, replace the invalid `my-queue` example with
`my_queue` and state the `[a-z0-9_]{1,47}` rule in plain language. Add an upgrade note to
`docs/user/pgmq-getting-started.md` near dependency and schema installation: run the
read-only mixed-case detection query before rollout; an empty result is safe; a non-empty
result requires the upstream transactional remediation before upgrading. Explain that
silent lowercasing and direct metadata edits are unsafe because different spellings may
already share a table and child rows can cascade. Reference `mori://shinzui/pgmq-hs`
together with `docs/design/016-queue-name-validation.md`, explicitly noting that the
artifact-level URI is pending.

Update `docs/pgmq-adapter/INTERNALS.md` so its `mkLease` excerpt and explanation show the
0.5 `Maybe Message` branch: only a returned message advances `lastVtRef`; a missing row is
a benign no-op. Update `docs/user/pgmq-advanced.md` so handler authors know that
`leaseExtend` returns normally when another operation has already removed the row. Do not
claim the adapter can extend or recover a nonexistent lease.

Add a 0.13.0.0 entry dated at implementation time to both `CHANGELOG.md` and
`shibuya-pgmq-adapter/CHANGELOG.md`. Describe the 0.5 family requirement, unchanged public
adapter signatures, the `Maybe Message` lease-race handling, stricter queue-name boundary
and pre-rollout remediation requirement, broader transient SQLSTATE classification inherited
from `pgmq-effectful`, and 0.5's notification crash-safety migration inherited through
`pgmq-migration`. Keep the root changelog concise and the package changelog precise. Do not
claim grouped-head reads or PGMQ 1.12 support: the released upstream 0.5 changelog explicitly
says grouped-head support is not in that release.

Run a textual audit for stale `pgmq-* 0.4` requirement claims. Historical passages about
the 0.4 migration-runner cutover and the old 0.3 ledger should remain; only current
requirements must say 0.5. Milestone acceptance is documentation that a new user can follow
without guessing and an operator-facing warning that prevents unsafe mixed-case rollout.

### Milestone 4 — Validate the released-package graph and finish the living plan

Run the formatter, whole-workspace build, complete adapter suite, capability checks, and
dependency-plan inspection in Concrete Steps. The tests use `ephemeral-pg`: they start
temporary PostgreSQL instances and apply `Migration.pgmqMigrations`; they do not connect to
a production database. Building with `--enable-benchmarks` compiles benchmark code without
running a performance workload. The resolved plan must report 0.5 for exactly the four
pgmq packages this workspace consumes.

Review `git diff --check`, `git diff --stat`, and `git status --short`. Update Progress with
timestamps and evidence, add any real surprises and decisions, and fill Outcomes &
Retrospective before the final commit. Use a Conventional Commit message such as
`fix(pgmq)!: upgrade to pgmq-hs 0.5`, with both required trailers:

```text
ExecPlan: docs/plans/4-upgrade-to-pgmq-hs-0-5.md
Intention: intention_01kzk9w7sqeg8tkwpm4z3xaw94
```

If documentation is committed separately, it must carry the same two trailers. Do not
create a feature branch. This milestone is accepted only when the committed tree contains
the completed living plan and every validation command is green.


## Concrete Steps

Run all commands from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
git status --short
```

The status may contain the plan itself and deliberate implementation edits. Preserve any
unrelated user changes and do not use a destructive reset.

Re-verify the dependency source, package registry, and upstream release tags before making
the version choice:

```bash
mori registry show shinzui/pgmq-hs --full
mori registry docs shinzui/pgmq-hs
for package in pgmq-core pgmq-hasql pgmq-effectful pgmq-migration pgmq-config; do
  printf '%s ' "$package"
  curl -fsSL "https://hackage.haskell.org/package/$package/preferred.json"
  printf '\n'
done
git ls-remote --tags --refs https://github.com/shinzui/pgmq-hs.git
```

At authoring time the relevant output was:

```text
pgmq-core ... "0.5.0.0" ...
pgmq-hasql ... "0.5.0.0" ...
pgmq-effectful ... "0.5.0.0" ...
pgmq-migration ... "0.5.0.0" ...
pgmq-config ... "0.5.0.0" ...
... refs/tags/v0.5.0.0
```

After editing the Cabal files, prove the bound inventory is complete:

```bash
rg -n '^\s*pgmq-(core|effectful|hasql|migration) \^>=0\.4' --glob '*.cabal' .
rg -n '^\s*pgmq-(core|effectful|hasql|migration) \^>=0\.5' --glob '*.cabal' .
rg -n '^version:' shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal shibuya-pgmq-example/shibuya-pgmq-example.cabal
```

The first command must produce no output. The second must produce 23 lines. The version
audit must show adapter 0.13.0.0 and the other two packages still at 0.1.0.0.

After adapting `mkLease` and adding the two regression examples, run the full suite rather
than relying on a fragile HSpec match expression:

```bash
cabal test shibuya-pgmq-adapter-test --enable-tests --test-show-details=direct
```

The output must include the two new example descriptions and end in this shape:

```text
154 examples, 0 failures
Test suite shibuya-pgmq-adapter-test: PASS
```

The number may be higher if other tests landed, but failures must be zero. Build every
component, including code that the test command does not compile by default:

```bash
cabal build all --enable-tests --enable-benchmarks
```

Inspect the actual solver plan rather than assuming the new bounds were honored:

```bash
jq -r '."install-plan"[] | select(."pkg-name"? | startswith("pgmq-")) | "\(."pkg-name")-\(."pkg-version")"' dist-newstyle/cache/plan.json | sort -u
```

At authoring time the expected output is:

```text
pgmq-core-0.5.0.0
pgmq-effectful-0.5.0.0
pgmq-hasql-0.5.0.0
pgmq-migration-0.5.0.0
```

Audit current-version prose while preserving deliberate history:

```bash
rg -n 'pgmq-(\*|core|effectful|hasql|migration).*0\.4|pgmq-migration 0\.4' README.md docs shibuya-pgmq-adapter/CHANGELOG.md shibuya-pgmq-example/README.md shibuya-pgmq-adapter-bench/README.md --glob '*.md' --glob '!docs/plans/**'
```

Any result must be read in context. References that describe the 0.4 runner cutover or the
0.3-to-0.4 ledger import remain true; a present-tense package requirement must say 0.5.

Finish with repository-wide checks:

```bash
nix fmt
just check-capabilities
nix flake check
git diff --check
git diff --stat
git status --short
```

If `nix fmt` changes files, inspect those changes, rerun it until no additional diff appears,
then rerun the build and test commands if it touched Haskell or Cabal files. Record short
validation transcripts in Progress or Outcomes & Retrospective.


## Validation and Acceptance

The upgrade is complete only when a user can resolve the repository from Hackage with no
local pgmq source override and Cabal's plan contains the latest normal 0.5 release of
`pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, and `pgmq-migration`, with no 0.4 pgmq
package. At authoring time that version is 0.5.0.0 for all four; if a 0.5 patch release is
newest during implementation, select it and update the recorded transcript. Every adapter,
test, example, benchmark, and endurance component must compile under that one graph.

The raced-away lease behavior must be demonstrated against PostgreSQL, not only inferred
from types. The new integration example reads a real row, deletes it, and calls
`leaseExtend`; it passes without an Effectful error and the queue remains empty. Existing
database-backed tests continue to prove ordinary reads, acknowledgements, retries, dead
lettering, shutdown, and prefetch behavior. The suite reports zero failures.

The new parser example must show the public boundary users receive after the upgrade:
`orders` parses, while `Orders` and the empty string do not. The configuration guide must
state the same `[a-z0-9_]{1,47}` rule and contain a valid `my_queue` example. The getting
started guide must tell an operator how to detect mixed-case metadata and what to do before
deployment; it must not recommend silent normalization or direct parent-row deletion.

`mkLease` keeps its public signature and successful-live-row behavior. `AckRetry` and
`AckHalt` continue to compile without adapter code changes because they discard the new
optional result. No `pgmq-config` dependency, local source override, production database
operation, or feature branch appears in the finished tree.

Finally, both changelogs and the Cabal version identify adapter 0.13.0.0 as the breaking
dependency-family upgrade, and the completed ExecPlan records the exact validation evidence.


## Idempotence and Recovery

The source, test, bound, and documentation edits are ordinary text changes and can be
reapplied or rerun safely. `cabal build`, the named test suite, `nix fmt`, capability
checks, and `nix flake check` are repeatable. The test suite uses temporary PostgreSQL
instances and uniquely generated lowercase queue names; it does not modify a developer's
long-lived or production database. A failed test run may leave ignored temporary build
artifacts, but the next run does not depend on their database state.

If dependency resolution unexpectedly selects 0.4 after the edits, do not add
`allow-newer` or a source override. Search all three Cabal files for a missed bound, rerun
`cabal build` to refresh `dist-newstyle/cache/plan.json`, and inspect the solver output. If
Hackage has published only part of a new shared family, retain the last complete released
family and record the registry inconsistency rather than mixing package versions.

If `mkLease` fails to compile, inspect the released signature in the Mori-resolved 0.5
source before changing logic. The safe adaptation has only two branches: `Nothing` leaves
the `IORef` alone; `Just message` writes `message.visibilityTime`. Do not replace the
optional result with `fromJust`, a fabricated message, or the locally computed target.

If a deployed database contains mixed-case rows, implementation work in this repository
must not touch that database. The operator should back up `pgmq.meta` plus its topic-binding
and notification-throttle children and run the canonical upstream transaction. That
transaction is designed to be rerunnable: after success, the detection query returns no
rows. Rolling back the adapter package does not repair aliasing metadata; the remediation
is the safe path even if application deployment is postponed.

If implementation must be abandoned before a commit, preserve unrelated user changes and
revert only the files owned by this ExecPlan through a reviewed patch. Never use
`git reset --hard` or broad checkout commands. If a commit has already been made, use a new
reverting commit with the ExecPlan and Intention trailers so history and rationale remain
visible.


## Interfaces and Dependencies

The authoritative dependency is `mori://shinzui/pgmq-hs`, verified against Hackage and the
upstream Git tag. This workspace uses its `pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, and
`pgmq-migration` packages at `^>=0.5`; it does not use `pgmq-config`. PostgreSQL is exercised
only through the existing `ephemeral-pg` test harness and the schema component exported by
`Pgmq.Migration`.

The released 0.5 interfaces that drive this plan are:

```haskell
-- pgmq-core, Pgmq.Types
parseQueueName :: Text -> Either PgmqError QueueName

-- pgmq-effectful, Pgmq.Effectful.Effect
changeVisibilityTimeout ::
  (Pgmq :> es) =>
  VisibilityTimeoutQuery ->
  Eff es (Maybe Message)

setVisibilityTimeoutAt ::
  (Pgmq :> es) =>
  VisibilityTimeoutAtQuery ->
  Eff es (Maybe Message)

-- pgmq-effectful, Pgmq.Effectful.Interpreter
isTransient :: PgmqRuntimeError -> Bool
```

`parseQueueName` accepts exactly `[a-z0-9_]{1,47}`. The visibility-timeout functions return
`Nothing` for a missing row instead of converting it into a statement row-count error.
`isTransient` now recognizes serialization failure (`40001`), deadlock (`40P01`), lock
unavailable (`55P03`), shutdown/recovery (`57P01`, `57P02`, `57P03`), and PostgreSQL class
53 resource errors in addition to the connection cases 0.4 already handled. The adapter's
existing `retryingTransient` helper consumes `isTransient`, so it inherits that broader
retry behavior without a new interface.

The adapter interface remains:

```haskell
-- shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs
mkLease ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Pgmq.Message ->
  Eff es (Lease es)
```

Inside `leaseExtend`, only `Just updatedMessage` advances `lastVtRef` to
`updatedMessage.visibilityTime`; `Nothing` returns `()`. No exposed module, record, error
type, constructor, or function signature in `Shibuya.Adapter.Pgmq` changes.
