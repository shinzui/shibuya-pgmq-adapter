---
id: 2
slug: upgrade-pgmq-hs-and-hs-opentelemetry
title: "Upgrade Shibuya, pgmq-hs, and hs-opentelemetry"
kind: exec-plan
created_at: 2026-05-31T22:30:28Z
intention: "intention_01kt01swj2ewssjjkj1vrffmqx"
---

# Upgrade Shibuya, pgmq-hs, and hs-opentelemetry

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, `shibuya-pgmq-adapter` builds against Shibuya `0.6.0.0`, the newly published `pgmq-hs` `0.3.0.0` release family, and the `hs-opentelemetry` 1.0 package family. Users can depend on the adapter without local path overrides for Shibuya or a git pin for `pgmq-hs`, run the example consumer with `Pgmq.Effectful.runPgmqTraced`, and receive Shibuya processing spans plus PGMQ operation spans whose messaging and database attributes follow the newest semantic-convention behavior exposed by `hs-opentelemetry`.

The visible result is a dependency and telemetry compatibility upgrade rather than a new public adapter feature. `cabal build all` should succeed with `shibuya-core` and `shibuya-metrics` at `0.6.0.0`, with `pgmq-core`, `pgmq-effectful`, `pgmq-hasql`, and `pgmq-migration` at `0.3.0.0`, with `hs-opentelemetry-api`, `hs-opentelemetry-sdk`, `hs-opentelemetry-otlp`, and `hs-opentelemetry-exporter-in-memory` at `1.0.0.0`, and with `hs-opentelemetry-semantic-conventions` at `1.40.0.0` or a newer compatible `1.x` release if one is available when implementation starts. The test suite should prove that trace context extraction and DLQ header preservation still work, and the example app should still initialize a tracer and pass it to `runPgmqTraced`.

`pgmq-hs` is being published to Hackage on 2026-05-31 and may take several minutes to appear in the package index. Shibuya `0.6.0.0` is already present in the sibling checkout at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`; implementation must verify whether it is visible on Hackage before removing the current `cabal.project.local` path override. The final committed state should prefer Hackage for Shibuya and `pgmq-hs` once their packages are available, using local sources only for source inspection or temporary propagation fallbacks.


## Progress

- [x] M1. Verify Shibuya, pgmq-hs, and hs-opentelemetry package availability and update dependency resolution.
- [x] M2. Build the adapter, tests, benchmarks, and example against the upgraded package set.
- [x] M3. Audit and validate OpenTelemetry semantic-convention behavior.
- [x] M4. Update documentation, changelogs, and commit the completed upgrade.


## Surprises & Discoveries

- `cabal info` on 2026-05-31 after `cabal update` showed the target Hackage versions were all visible: `shibuya-core-0.6.0.0`, `shibuya-metrics-0.6.0.0`, the `pgmq-*` `0.3.0.0` packages, and the `hs-opentelemetry` 1.0 packages.
- `OpenTelemetry.Trace.shutdownTracerProvider` in `hs-opentelemetry-sdk-1.0.0.0` now takes a timeout argument and returns a `ShutdownResult`, so the example has to call `shutdownTracerProvider provider Nothing` and discard the result in both real and no-op tracing paths.
- `cabal test --enable-tests shibuya-pgmq-adapter-test --test-options='--match /Convert/'` compiled and passed but selected zero examples. The full adapter suite is the meaningful validation for the existing trace-header and DLQ behavior.
- Running duplicate Cabal builds for the same example package concurrently can race in `dist-newstyle` package registration. The transient `package.conf.inplace` removal failure disappeared when the builds were rerun sequentially.


## Decision Log

- Decision: Target Shibuya package versions `0.6.0.0` for both `shibuya-core` and `shibuya-metrics`.
  Rationale: The current effective build uses `cabal.project.local` entries `../shibuya/shibuya-core` and `../shibuya/shibuya-metrics`. Those sibling cabal files report `version: 0.6.0.0`, and `../shibuya/CHANGELOG.md` says `0.6.0.0` is the OpenTelemetry 1.0 semantic-conventions release where processing spans emit `messaging.operation.type = "process"` instead of the deprecated `messaging.operation = "process"` key.
  Date: 2026-05-31

- Decision: Target `pgmq-hs` package versions `0.3.0.0` for `pgmq-core`, `pgmq-effectful`, `pgmq-hasql`, and `pgmq-migration`, while allowing the implementation to verify Hackage propagation before editing final bounds.
  Rationale: `mori registry show shinzui/pgmq-hs --full` points to `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`, and the cabal files in that checkout report `version: 0.3.0.0` for those packages. The user also noted that `pgmq-hs` is now being published to Hackage and should become available shortly.
  Date: 2026-05-31

- Decision: Treat `hs-opentelemetry` 1.0 and `hs-opentelemetry-semantic-conventions` `>=1.40 && <2` as the target telemetry dependency family.
  Rationale: `mori registry show iand675/hs-opentelemetry --full` identifies the local corpus at `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`; the cabal files there show `hs-opentelemetry-api` and `hs-opentelemetry-sdk` at `1.0.0.0`, and `hs-opentelemetry-semantic-conventions` at `1.40.0.0`. The generated semantic-conventions module contains the stable keys `messaging.operation.name`, `messaging.operation.type`, `db.system.name`, and `db.operation.name`.
  Date: 2026-05-31

- Decision: Preserve the adapter's `Envelope.attributes = HashMap.empty` behavior unless implementation discovers a new, adapter-owned attribute contract in `shibuya-core` or `pgmq-hs`.
  Rationale: The adapter currently leaves `Envelope.attributes` empty because PGMQ-specific message attributes are emitted by the `pgmq-effectful` traced interpreter rather than by `Shibuya.Adapter.Pgmq.Convert.pgmqMessageToEnvelope`. Shibuya `0.6.0.0` owns processing-span defaults, and the inspected `pgmq-effectful` source owns PGMQ operation-span attributes.
  Date: 2026-05-31

- Decision: Remove the committed `hs-opentelemetry` git `source-repository-package` and remove the local Shibuya override from the effective build.
  Rationale: Hackage now provides the needed `hs-opentelemetry` 1.0 family and Shibuya `0.6.0.0` packages. Keeping the git pin or local `cabal.project.local` path override would hide whether users can solve the release-ready package set from Hackage.
  Date: 2026-05-31

- Decision: Do not add adapter-owned in-memory exporter assertions in this upgrade.
  Rationale: The adapter owns W3C trace-header movement and DLQ header preservation, which are covered by the existing suite. Shibuya owns processing-span semantic conventions and `pgmq-effectful` owns PGMQ operation-span semantic conventions. This change validated those dependency contracts through source inspection and dependency builds instead of duplicating dependency test coverage in the adapter.
  Date: 2026-05-31


## Outcomes & Retrospective

The repository now targets Shibuya `0.6.0.0`, `pgmq-hs` `0.3.0.0`, and `hs-opentelemetry` 1.0 from Hackage. The old `hs-opentelemetry` git pin was removed from `cabal.project`, package bounds were updated across the adapter, benchmark, and example packages, and the stale local Shibuya path override was removed from the effective workspace. The adapter package version is now `0.6.0.0`.

The only source change required was in `shibuya-pgmq-example/src/Example/Telemetry.hs`, where tracer-provider shutdown now passes `Nothing` as the timeout argument and discards the `ShutdownResult`. Adapter library code compiled unchanged, which matches the dependency audit: Shibuya owns the processing-span change to `messaging.operation.type = "process"`, and `pgmq-effectful` owns PGMQ operation-span stable/old/duplicate attribute behavior through `OTEL_SEMCONV_STABILITY_OPT_IN`.

Validation completed:

```bash
cabal build shibuya-pgmq-adapter:lib:shibuya-pgmq-adapter
cabal build shibuya-pgmq-example:exe:shibuya-pgmq-consumer
cabal build shibuya-pgmq-example:exe:shibuya-pgmq-simulator
cabal build shibuya-pgmq-adapter-bench:bench:shibuya-pgmq-adapter-bench
cabal build all
PGMQ_TEST_SKIP_DB=1 cabal test --enable-tests shibuya-pgmq-adapter-test
cabal test --enable-tests shibuya-pgmq-adapter-test
```

Both adapter test runs passed. The skip-db run reported 125 examples, 0 failures, and 12 pending database-dependent examples. The full database-backed run reported 125 examples and 0 failures. Runtime OTLP export was not exercised against a collector in this change.


## Context and Orientation

This repository is a Haskell workspace named `shinzui/shibuya-pgmq-adapter`. Running `mori show --full` from the repository root identifies three packages.

`shibuya-pgmq-adapter` is the library package in `shibuya-pgmq-adapter/`. Its main public module is `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs`. Its implementation lives mainly in `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`, and its type conversion code lives in `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs`.

`shibuya-pgmq-adapter-bench` is the benchmark package in `shibuya-pgmq-adapter-bench/`. It depends on the adapter and on the `pgmq-hs` packages to benchmark send, read, ack, FIFO, multi-queue, and throughput behavior.

`shibuya-pgmq-example` is the runnable example package in `shibuya-pgmq-example/`. It has a simulator and a consumer. The consumer in `shibuya-pgmq-example/app/Consumer.hs` imports `Pgmq.Effectful.runPgmqTraced` and runs the Shibuya `Tracing` effect around the adapter. The telemetry setup in `shibuya-pgmq-example/src/Example/Telemetry.hs` imports `OpenTelemetry.Trace qualified as OTel` and constructs a tracer with `OTel.initializeGlobalTracerProvider`, `OTel.shutdownTracerProvider`, and `OTel.makeTracer`.

The workspace resolver is `cabal.project`. It currently lists the three local packages and a `source-repository-package` for `https://github.com/iand675/hs-opentelemetry` at commit `adc464b0a45e56a983fa1441be6e432b50c29e0e` with subdirectories `api`, `sdk`, `otlp`, `propagators/w3c`, `semantic-conventions`, and `exporters/in-memory`. That pin was introduced for GHC 9.12 support before `hs-opentelemetry` 1.0 was available as the intended dependency target. The implementation should remove or revise this pin only after proving Hackage can solve the same packages at `1.0.0.0`; if the pin is still necessary for unreleased subpackages, update it to a release commit and record why.

The working tree also has `cabal.project.local`. That file currently adds sibling local packages `../shibuya/shibuya-core` and `../shibuya/shibuya-metrics`; those local packages are both `0.6.0.0` at clean Shibuya commit `1b86540`. This means the current effective local build already uses Shibuya `0.6.0.0`, even though `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal` still says `shibuya-core ^>=0.5.0.0` and the example package leaves `shibuya-core` and `shibuya-metrics` unbounded. The upgrade must make the committed bounds match the intended dependency version and should remove the local override if Hackage contains the same Shibuya release.

Shibuya `0.6.0.0` is a telemetry compatibility release. Its changelog says `shibuya-core` processing spans now emit `messaging.operation.type = "process"` instead of deprecated `messaging.operation = "process"`. Source code imports of `attrMessagingOperation` continue to compile because the Haskell constant keeps the same name and points at the new wire key. Dashboards and trace queries that filter on `messaging.operation` must switch to `messaging.operation.type`.

The current library bounds in `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal` use `pgmq-core ^>=0.2`, `pgmq-effectful ^>=0.2`, and `pgmq-hasql ^>=0.2`. The test suite additionally uses `pgmq-migration ^>=0.2`. The example and benchmark cabal files also use `^>=0.2` bounds for `pgmq-hs` packages. These are the bounds to move to the newly published release family.

`pgmq-hs` means the group of Haskell packages that wrap PGMQ, PostgreSQL Message Queue. PGMQ is a PostgreSQL extension and schema that provide queue operations such as send, read, archive, delete, visibility-timeout changes, FIFO grouped reads, and topic routing. The dependency source discovered through `mori registry show shinzui/pgmq-hs --full` is `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`. Its cabal files currently report:

```text
pgmq-core/pgmq-core.cabal:version:         0.3.0.0
pgmq-hasql/pgmq-hasql.cabal:version:      0.3.0.0
pgmq-effectful/pgmq-effectful.cabal:version: 0.3.0.0
pgmq-migration/pgmq-migration.cabal:version: 0.3.0.0
```

`hs-opentelemetry` means the Haskell OpenTelemetry package family. OpenTelemetry is a vendor-neutral telemetry system for traces, metrics, and logs. A span is a timed unit of work in a trace. A semantic convention is a standard attribute name and value meaning, such as `messaging.system = "pgmq"` or `db.system.name = "postgresql"`, so dashboards and backends can understand telemetry consistently.

The local `hs-opentelemetry` corpus is `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`. Its cabal files show `hs-opentelemetry-api` and `hs-opentelemetry-sdk` at `1.0.0.0`, and `hs-opentelemetry-semantic-conventions` at `1.40.0.0`. The generated `OpenTelemetry.SemanticConventions` module contains both older compatibility keys such as `messaging.operation` and `db.operation`, and stable keys such as `messaging.operation.name`, `messaging.operation.type`, `db.system.name`, and `db.operation.name`.

`OTEL_SEMCONV_STABILITY_OPT_IN` is an OpenTelemetry environment variable used by instrumentations to choose old, stable, or duplicate semantic-convention attributes during migrations. The inspected `pgmq-effectful` `0.3.0.0` README says the traced interpreter preserves older v1.24 attribute names by default, emits stable messaging and database attributes when `OTEL_SEMCONV_STABILITY_OPT_IN=messaging,database`, and emits both old and stable attributes when `OTEL_SEMCONV_STABILITY_OPT_IN=messaging/dup,database/dup`.


## Plan of Work

Milestone 1 updates dependency resolution. First verify what Hackage can see at implementation time. Run `cabal update`, then query or attempt a dry build with `shibuya-core ==0.6.0.0`, `shibuya-metrics ==0.6.0.0`, `pgmq-core ==0.3.0.0`, `pgmq-effectful ==0.3.0.0`, `pgmq-hasql ==0.3.0.0`, `pgmq-migration ==0.3.0.0`, and the `hs-opentelemetry` packages at `1.0.0.0`. If Hackage has not yet indexed Shibuya `0.6.0.0` or `pgmq-hs 0.3.0.0`, temporarily keep or add local `packages:` entries to continue API validation, but do not leave local path overrides as the final state unless the user explicitly accepts a non-Hackage pin. Edit `cabal.project` so the final dependency source prefers Hackage for Shibuya, `pgmq-hs`, and `hs-opentelemetry` 1.0 packages where possible. Update `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`, `shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal`, and `shibuya-pgmq-example/shibuya-pgmq-example.cabal` so Shibuya bounds accept `0.6.0.0`, `pgmq-*` bounds accept `0.3.0.0`, and `hs-opentelemetry-*` bounds accept `1.0.0.0`.

Milestone 2 compiles and adapts code to any API changes. Build the library first, then the tests, then the example and benchmark packages. If compiler errors appear, inspect the dependency source through `mori` before changing code. The most likely touch points are imports from `Pgmq.Effectful.Effect`, records from `Pgmq.Hasql.Statements.Types`, `Pgmq.Types.Message`, Shibuya telemetry helpers, and `OpenTelemetry.Trace` construction in `shibuya-pgmq-example/src/Example/Telemetry.hs`. Keep changes local to the adapter, example, benchmark, and package metadata unless a build error proves a shared helper must change.

Milestone 3 validates telemetry semantics. Read the Shibuya `0.6.0.0` processing-span code and the `pgmq-effectful` traced interpreter source at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful/src/Pgmq/Effectful/Interpreter/Traced.hs`. Confirm the adapter calls the traced interpreter in a way that allows Shibuya to own per-message processing spans and `pgmq-effectful` to own PGMQ operation spans. Then run focused tests that cover trace header extraction and DLQ header merging in `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConvertSpec.hs` and `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/InternalSpec.hs`. If the adapter has or gains in-memory exporter tests, add assertions for all three semconv modes: default old keys, stable keys with `OTEL_SEMCONV_STABILITY_OPT_IN=messaging,database`, and duplicate keys with `OTEL_SEMCONV_STABILITY_OPT_IN=messaging/dup,database/dup`. The Shibuya processing span assertion should expect `messaging.operation.type = "process"` rather than deprecated `messaging.operation = "process"`. If no exporter-based test harness exists, record that gap in Outcomes and rely on Shibuya and `pgmq-effectful`'s own tests plus adapter compile and header tests.

Milestone 4 updates user-facing text and commits. Update `README.md`, `shibuya-pgmq-adapter/CHANGELOG.md`, `shibuya-pgmq-example/README.md`, and any docs under `docs/` that still claim the adapter is aligned only with OpenTelemetry messaging semantic conventions v1.24 or Shibuya `0.5`. The wording should explain that Shibuya `0.6.0.0` emits `messaging.operation.type = "process"` for processing spans, and that `pgmq-effectful 0.3.0.0` / `hs-opentelemetry` 1.0 preserve old attributes by default and support stable or duplicate attributes through `OTEL_SEMCONV_STABILITY_OPT_IN`. Run formatting, tests, and builds. Commit with a Conventional Commit message and include both trailers:

```text
ExecPlan: docs/plans/2-upgrade-pgmq-hs-and-hs-opentelemetry.md
Intention: intention_01kt01swj2ewssjjkj1vrffmqx
```


## Concrete Steps

From the repository root `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`, start by confirming the project and dependency registry:

```bash
mori show --full
mori registry show shinzui/shibuya --full
mori registry show shinzui/pgmq-hs --full
mori registry show iand675/hs-opentelemetry --full
mori registry docs shinzui/shibuya
mori registry docs shinzui/pgmq-hs
mori registry docs iand675/hs-opentelemetry
```

The important expected facts are that this repo has packages `shibuya-pgmq-adapter`, `shibuya-pgmq-adapter-bench`, and `shibuya-pgmq-example`; Shibuya is registered at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`; `pgmq-hs` is registered at `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`; and `hs-opentelemetry` is registered at `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`.

Check package availability:

```bash
cabal update
cabal info shibuya-core
cabal info shibuya-metrics
cabal info pgmq-core
cabal info pgmq-effectful
cabal info pgmq-hasql
cabal info pgmq-migration
cabal info hs-opentelemetry-api
cabal info hs-opentelemetry-sdk
cabal info hs-opentelemetry-semantic-conventions
```

Expected successful output includes `Versions available: ... 0.6.0.0` for `shibuya-core` and `shibuya-metrics`, `Versions available: ... 0.3.0.0` for the `pgmq-*` packages, and `Versions available: ... 1.0.0.0` for `hs-opentelemetry-api` and `hs-opentelemetry-sdk`. If the Shibuya or `pgmq-*` output does not yet include the target version, wait a few minutes, rerun `cabal update`, and retry. If implementation must continue before propagation finishes, keep or add a temporary local source to `cabal.project.local` rather than committing it:

```cabal
packages:
  ../shibuya/shibuya-core
  ../shibuya/shibuya-metrics
  /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-core
  /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-hasql
  /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful
  /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-migration
```

Edit package metadata:

```bash
$EDITOR cabal.project
$EDITOR shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal
$EDITOR shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal
$EDITOR shibuya-pgmq-example/shibuya-pgmq-example.cabal
```

The final committed cabal files should accept these dependency families:

```text
shibuya-core ^>=0.6.0.0
shibuya-metrics ^>=0.6.0.0
pgmq-core ^>=0.3
pgmq-effectful ^>=0.3
pgmq-hasql ^>=0.3
pgmq-migration ^>=0.3
hs-opentelemetry-api ^>=1.0
hs-opentelemetry-sdk ^>=1.0
hs-opentelemetry-otlp ^>=1.0
hs-opentelemetry-exporter-in-memory ^>=1.0
hs-opentelemetry-semantic-conventions >=1.40 && <2
```

Build incrementally:

```bash
cabal build shibuya-pgmq-adapter:lib:shibuya-pgmq-adapter
cabal build shibuya-pgmq-adapter:test:shibuya-pgmq-adapter-test
cabal build shibuya-pgmq-example:lib:shibuya-pgmq-example
cabal build shibuya-pgmq-example:exe:shibuya-pgmq-consumer
cabal build shibuya-pgmq-example:exe:shibuya-pgmq-simulator
cabal build shibuya-pgmq-adapter-bench:bench:shibuya-pgmq-adapter-bench
```

Run focused and broad tests:

```bash
cabal test shibuya-pgmq-adapter-test --test-options='--match /Convert/'
cabal test shibuya-pgmq-adapter-test --test-options='--match /Internal/'
PGMQ_TEST_SKIP_DB=1 cabal test shibuya-pgmq-adapter-test
```

The focused test commands should pass all selected examples. The `PGMQ_TEST_SKIP_DB=1` command should pass non-database tests and report database-dependent tests as skipped or pending if that behavior remains in the suite.

Run the full build before committing:

```bash
cabal build all
cabal test shibuya-pgmq-adapter-test
```

If `cabal test shibuya-pgmq-adapter-test` requires a local PostgreSQL instance and fails only because PostgreSQL is unavailable, record the exact failure in Surprises & Discoveries and run the documented skip-db command as the minimum acceptance fallback.


## Validation and Acceptance

The upgrade is accepted when `cabal.project` and the package cabal files no longer force the old Shibuya `0.5` family, old `pgmq-hs 0.2` family, or old `hs-opentelemetry 0.3` API bounds, and when the final dependency solver uses Shibuya `0.6.0.0`, `pgmq-hs 0.3.0.0`, and `hs-opentelemetry` 1.0 packages from Hackage or a documented release pin.

The library acceptance command is:

```bash
cabal build shibuya-pgmq-adapter:lib:shibuya-pgmq-adapter
```

It should finish successfully with no source changes outside the adapter's package metadata unless API changes require them.

The adapter behavior acceptance command is:

```bash
PGMQ_TEST_SKIP_DB=1 cabal test shibuya-pgmq-adapter-test
```

It should pass the non-database suite. In particular, tests around `extractTraceHeaders`, `pgmqMessageToEnvelope`, and `mergeDlqHeaders` should continue proving that W3C `traceparent` and `tracestate` headers move through envelopes and DLQ writes correctly.

The example acceptance command is:

```bash
cabal build shibuya-pgmq-example:exe:shibuya-pgmq-consumer
```

It should compile with `Pgmq.Effectful.runPgmqTraced`, `Shibuya.Telemetry.Effect.runTracing`, and `Example.Telemetry.withTracing` using the 1.0 OpenTelemetry API. If an actual database and OTLP collector are available, run:

```bash
OTEL_TRACING_ENABLED=true OTEL_SEMCONV_STABILITY_OPT_IN=messaging,database cabal run shibuya-pgmq-consumer
```

Then send messages with the simulator and verify that Shibuya processing spans use `messaging.operation.type = "process"` and exported PGMQ spans use stable attributes such as `messaging.operation.name`, `messaging.operation.type`, `db.system.name`, and `db.operation.name`. This runtime telemetry check is optional if the local machine lacks PostgreSQL or an OTLP collector, but the plan implementer must record whether it was run.


## Idempotence and Recovery

All metadata edits are safe to repeat. If Hackage propagation is incomplete, rerun `cabal update` and the `cabal info` commands; do not commit a temporary `cabal.project.local` fallback unless the final decision is to keep local development overrides outside the release-ready state. If a temporary local fallback was used, remove it before final validation and rerun the build against the intended final dependency source.

If the solver selects an older dependency version, add explicit bounds in the relevant cabal file rather than relying on an accidental transitive constraint. If the solver cannot select Shibuya `0.6.0.0` or `hs-opentelemetry` 1.0 from Hackage for all required subpackages, use a release tag, source-repository-package, or documented local override in `cabal.project` and document the exact reason in Surprises & Discoveries and Decision Log.

Do not revert unrelated changes in the working tree. At plan creation time, `docs/plans/1-migrate-to-shibuya-core-0.5-and-dlq-trace.md` was already modified. Leave it alone unless the user explicitly asks to change it.


## Interfaces and Dependencies

The adapter library must continue exposing `Shibuya.Adapter.Pgmq.pgmqAdapter` with its current behavior. The main dependency-facing implementation points are:

`shibuya-core 0.6.0.0` remains the owner of Shibuya processor spans. The relevant modules are `Shibuya.Runner.Supervised`, `Shibuya.Telemetry.Effect`, `Shibuya.Telemetry.Propagation`, and `Shibuya.Core.Types`. `Envelope` still has the `attributes :: HashMap Text Attribute` field added in `0.5.0.0`, and `currentTraceHeaders :: (Tracing :> es, IOE :> es) => Eff es (Maybe TraceHeaders)` still returns W3C headers for the active span. The new semantic-convention behavior to preserve is that Shibuya processing spans use `messaging.operation.type = "process"`.

`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` imports `Pgmq.Effectful.Effect` operations such as `readMessage`, `readWithPoll`, `readGrouped`, `readGroupedRoundRobin`, `sendMessage`, `sendMessageWithHeaders`, `sendTopic`, and `sendTopicWithHeaders`. It constructs `Pgmq.Hasql.Statements.Types` records such as `ReadMessage`, `ReadWithPollMessage`, `ReadGrouped`, `ReadGroupedWithPoll`, `MessageQuery`, `VisibilityTimeoutQuery`, `SendMessage`, `SendMessageWithHeaders`, `SendTopic`, and `SendTopicWithHeaders`.

`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` uses `Pgmq.Types.Message`, `Pgmq.Types.MessageId`, `Pgmq.Types.MessageBody`, and optional JSON headers to produce a Shibuya `Envelope Value`. It must continue extracting `traceparent` and optional `tracestate` into `TraceHeaders`.

`shibuya-pgmq-example/app/Consumer.hs` uses `Pgmq.Effectful.runPgmqTraced` and `Pgmq.Effectful.Interpreter.PgmqRuntimeError`. Those names must still resolve after the upgrade, or the example must be updated to the new module names after checking the `pgmq-hs` source.

`shibuya-pgmq-example/src/Example/Telemetry.hs` uses `OpenTelemetry.Trace` APIs to initialize and shut down a tracer provider. If `hs-opentelemetry` 1.0 changes `InstrumentationLibrary` construction or tracer provider setup, update this file according to the local `hs-opentelemetry` source and docs found through `mori`.

The PGMQ operation-span semantic-convention contract is owned by `pgmq-effectful` after this upgrade. The adapter should not hand-type or duplicate PGMQ operation span attributes unless the `pgmq-effectful` traced interpreter stops doing so. The expected dependency behavior is:

```text
Default: old compatibility keys such as messaging.operation, db.system, and db.operation.
OTEL_SEMCONV_STABILITY_OPT_IN=messaging,database: stable keys such as messaging.operation.name, messaging.operation.type, db.system.name, and db.operation.name.
OTEL_SEMCONV_STABILITY_OPT_IN=messaging/dup,database/dup: both old and stable keys.
```


## Revision Notes

2026-05-31: Revised the plan to include Shibuya `0.6.0.0` as a first-class target alongside `pgmq-hs 0.3.0.0` and `hs-opentelemetry 1.0.0.0`. The change was made because the current build already uses sibling local Shibuya `0.6.0.0` through `cabal.project.local`, and the user requested that the adapter upgrade Shibuya as part of this work.
