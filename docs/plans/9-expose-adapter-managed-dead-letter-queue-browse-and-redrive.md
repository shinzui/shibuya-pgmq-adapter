---
id: 9
slug: expose-adapter-managed-dead-letter-queue-browse-and-redrive
title: "Expose adapter-managed dead-letter queue browse and redrive"
kind: exec-plan
created_at: 2026-10-26T03:53:06Z
intention: "intention_01m5v5br8qewxvh359b0hpw6cw"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-26T03:53:06Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-26T04:05:34Z
      mode: "update"
      note: "Require controlled performance baselines, numeric regression gates, administrative-load isolation measurements, and reproducible evidence before completion."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-26T04:18:38Z
      mode: "implement"
      note: "Implement administration API and PostgreSQL proofs; retain released-dependency and performance acceptance gates."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-27T02:14:13Z
      mode: "implement"
      note: "Resume against released PGMQ 0.7.0.0; complete unflagged administration and performance acceptance tooling and evidence."
---


# Expose adapter-managed dead-letter queue browse and redrive


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Follow `agents/skills/exec-plan/PLANS.md`, `ADR.md`, and `FRICTION.md` in that skill directory during implementation. This plan implements [IR-3](../improvement-requests/expose-dead-letter-queue-browse-and-redrive-for-adapter-managed-dlqs.md).

## Purpose / Big Picture


An operator will be able to inspect messages in an adapter-managed dead-letter queue (DLQ), see why each failed, fetch one by its queue-local message ID, and explicitly return one to its original queue after correcting the cause. Inspection must not lease messages or change delivery counters. Redrive means atomically removing a chosen DLQ entry and inserting its original payload into the source queue; it is disabled unless the host enables it.

Deliver an in-process Haskell API and real PostgreSQL tests. HTTP endpoints, a browser UI, a live feed, bulk redrive, and archive recovery are outside this plan. A host can later expose these operations through its own transport. The primary demonstration is a real handler returning an application-defined `AckDeadLetter`, followed by browse, fetch, a refused default redrive, and an enabled redrive that creates exactly one source message despite retry and concurrency.

Completion also requires measured performance acceptance. Compare existing worker behavior with a fixed pre-feature baseline, quantify the cost of the new source field, and measure workers while administrative calls share their database. The limits below define acceptable measured overhead for specified workloads; they do not promise zero overhead or performance isolation under arbitrary administrative load.

## Progress


- [ ] M1 — Establish a supported dependency baseline, capture reproducible pre-feature performance measurements, and prove the public producer-to-browse path against real PostgreSQL, including source identity and exact reason fields.
- [x] M2 — Bounded browse/fetch, historical decoding and explicit physical registrations verified against released PGMQ 0.7.0.0 in the normal unflagged PostgreSQL suite on 2026-10-26. Tests compare all seven raw row fields, preserve invisible/malformed rows, cover 500-row lookahead, reject invalid requests before I/O, and verify separate-pool deadlines and setting cleanup.
- [x] M3 — Default-off row-locked delete/send transactions verified on 2026-10-26 against released PGMQ 0.7.0.0, without a flag or temporary project. The clean final correctness suite passed 203 examples with zero failures, including 20 administration scenarios covering saved/missing/null headers, null payloads, normal handler input, concurrency, response-discard retry, rollback/recovery, cancellation, authorization and distinct topic fan-out copies.
- [ ] M4 — Pass the numeric performance gates with retained baseline/candidate evidence, complete operator documentation and durable records, and pass the final released-dependency build and test checks.

Resume, 2026-10-26: verified Hackage publishes `pgmq-hasql 0.7.0.0` with `Pgmq.Hasql.Statements.Inspection`; upstream tag `v0.7.0.0` resolves to commit `88afb93802f790c1ecfbd3ed8bcce196c4430d13`. Commit `e5f26b7` adopts the released family and records all components building and 203 tests passing with administration enabled. The dependency-release prerequisite is satisfied. Remove the transitional flag and repeat final acceptance on the current candidate, including the committed `shibuya-core 0.12.0.0` compatibility update. M1 remains open for complete reproducible performance controls; M4 remains open for the full performance gates and final checks. The preserved pre-feature commit remains `e06e64b268055aca4eff78caabd1b0eb73aa1cd1`.

## Surprises & Discoveries

2026-10-25 — PGMQ's public `MessageHeaders` wraps arbitrary JSON, not only an object. Preserve any saved JSON header value, including scalars and arrays; only absent `original_headers` uses DLQ headers. Restricting that field to objects would reject valid adapter-produced envelopes. A dedicated real-database test covers these values.

2026-10-25 — The upstream checkout has advanced to the unreleased `0.7.0.0` family at `fe2804f87115c8b5bcd20dfe29596e0f3f996674`; its only uncommitted change during inspection was an unrelated ADR. Released inspection remains unavailable (FRIC-1 in `docs/friction-log/`). A temporary project outside this repository supplies its four local family packages and explicit temporary solver allowances; tracked production dependency bounds remain unchanged.


2026-10-26 — The first complete seven-pair `ack-one` comparison in `.dev/dlq-release-id-counted/` failed throughput bounds (1.081977 versus original, 1.085166 versus matched; limit 1.052632) and original-control p95 (1.303030; limit 1.10), while all three allocation gates passed. These are retained failed measurements, not performance acceptance. The user explicitly reaffirmed keeping the original gates. An eight-run short scheduler diagnostic found nearly identical original/candidate results with both one and four runtime capabilities; it is not acceptance evidence.

2026-10-26 — A disposable database observed during a measured interval had an active `autovacuum: VACUUM ANALYZE pgmq.q_perf_source`, 1,308,804 estimated dead tuples, and two requested checkpoints with only one completed. Retain `.dev/dlq-autovacuum-diagnostic.log`. Bulk fixture setup was outside the timer, but automatic seed-triggered maintenance was not. This confounds paired measurements. Configure only disposable benchmark tables with automatic maintenance disabled, manually vacuum/analyze them and checkpoint before warmup, and retain maintenance counters/options with every worker result. Reject measurements with missing stabilization or unexpected automatic maintenance. Use identical preparation on original, matched and candidate; preserve all workload sizes/rates, pools, durations, runtime capabilities and numeric budgets. The prior full attempt is interrupted and retained; restart all comparisons after the shared instrumentation change.

## Decision Log


2026-10-25 — Implement the minimum in-process API in the adapter package and defer transports and the optional feed. The request explicitly permits this scope, and no web dependencies are necessary for adapter semantics.

2026-10-25 — Consume upstream non-destructive inspection statements once released; do not recreate a general queue browser here. A temporary local dependency project may prove the integration before release, but is not the production dependency solution.

2026-10-25 — Add `original_queue` to new adapter-produced DLQ envelopes, independently of `includeMetadata`, while preserving the existing `mkDlqPayload` signature and reason fields. The source identity is needed for shared/topic DLQs and safe redrive; historical rows cannot recover it from the envelope alone. Missing original delivery counts remain unknown rather than using the DLQ row's own count.

2026-10-25 — Require a host-defined mapping from each managed physical DLQ to its allowed source queues. The default configuration disables redrive; a payload's queue name cannot grant permission to send to an arbitrary queue. Reject source/DLQ self-mappings. Topic destinations must be registered explicitly rather than guessed from a routing key.

2026-10-25 — Define idempotence per physical DLQ queue and message ID, using the row as the durable claim. Returning `AlreadyAbsent` after a retry is honest: without a receipt table, absence cannot prove who removed a row. Distinct topic fan-out copies are distinct entries and can each be redriven; global deduplication across them is outside this guarantee.

2026-10-25 — At the user's request, make performance a completion gate rather than relying on separate pools and timeouts. Preserve a fixed baseline and require the numeric limits in Validation and Acceptance. These are chosen engineering budgets, not existing measurements. A failed or inconclusive result leaves M4 open; changing a limit requires an explicit user scope decision and a recorded rationale, not an implementation-time adjustment to make a result pass.

2026-10-25 — Temporarily guard the administration exports and spec with the manual, default-off Cabal flag `dlq-admin`. This keeps the normal released-dependency build usable while allowing the explicitly permitted local integration proof. Before accepting M1/M4, remove this transitional flag, require the verified inspection release in both component bounds, and run the documented unflagged acceptance commands. The worker's queue-aware writer does not require the flag.

2026-10-26 — Preserve the original numeric gates, as explicitly reaffirmed by the user after the first failing case. Control asynchronous fixture-maintenance timing uniformly in the disposable benchmark setup; this is an experiment reproducibility correction, not a production database policy or a relaxation of acceptance.

## Outcomes & Retrospective

Resume checkpoint, 2026-10-26: the released PGMQ 0.7.0.0 dependency is adopted, and the temporary `dlq-admin` flag has been removed from the library and tests. The normal unflagged PostgreSQL suite passes 203 examples with zero failures, including all 20 administration scenarios and the public embedding example. Haddock and strict bundle validations pass. A fresh `dist-dlq-release` build compiles all components; a reused build directory retained incompatible dependency identities (FRIC-2 in `docs/friction-log/`). The separate `shibuya-core 0.12.0.0` dependency update is now committed as `6241ed8` and is included in the final candidate.

FRIC-1 is resolved by the published inspection release. The durable administration decisions remain in [ADR 0002](../adr/0002-managed-dlq-administration.md). The complete acceptance orchestrator now exists at `scripts/check-dlq-performance.py`, with common baseline-compatible worker instrumentation and candidate-only administration/encoding/read/retention measurements. Seven tests protect statistical ratio direction, incomplete evidence rejection, request failures and index-plan checks. Short smoke experiments are tooling diagnostics and always exit nonzero; they do not close any numeric gate.

This plan remains incomplete until the original/matched/candidate experiment passes every numeric gate. Preserve the fixed baseline and all failed/inconclusive runs. Final results, exact reproduction and retained artifact locations belong in `docs/performance/9-dlq-browse-and-redrive.md`. IR-3 remains proposed until complete acceptance; no external release or tag has been published by this plan.

## Context and Orientation


The adapter is a library, currently version `0.17.0.0` in `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`. PGMQ is PostgreSQL-backed message queuing. A read leases a message by changing its visibility deadline (`vt`) and incrementing `read_ct`; browsing must instead use ordinary observation without leasing. IDs belong to a queue, so every fetch, cursor, and redrive must retain the DLQ identity.

`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs` defines `PgmqAdapterConfig`, `DeadLetterConfig`, and `DeadLetterTarget`. A target is either `DirectQueue QueueName` or `TopicRoute RoutingKey`; topics may copy one failure to several physical queues. With no target configured, dead-lettering archives rather than creating a DLQ row. Archives are not managed DLQs for this feature.

`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` contains public `mkDlqPayload`. Its actual contract differs from the request's prose: it currently writes `original_message`, the legacy rendered string `dead_letter_reason`, the stable string `dead_letter_reason_code`, and `dead_letter_reason_detail`. Detail is currently a JSON string or null because the core's producer accepts text, not arbitrary JSON. `includeMetadata` additionally writes original ID, enqueue time, last-read time, `read_count`, and original headers. It does not write the original queue. Preserve all reason fields; the separately deferred [Plan 6](6-remove-the-legacy-dead-letter-reason-field-after-structured-rollout.md) must not be implemented here. [Plan 5](5-preserve-structured-dead-letter-reasons-in-pgmq-dlq-payloads.md) established the structured code/detail fields this reader consumes.

`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` implements `deadLetterTransactionally`: inside one `ReadCommitted` write transaction, delete the source row and send only when deletion succeeds. Sending failure rolls back the deletion. [ADR 0001](../adr/0001-idempotent-dead-letter-moves.md) requires this durable claim and documents why an in-memory flag alone cannot prevent duplicates after a lost commit response. Apply the same principle in the reverse direction. The local ADR directory uses ordinary Markdown, not a profiled OKF bundle; `mori show --full` currently declares no ADR bundle. Preserve that convention when recording redrive's gate and guarantees.

`shibuya-pgmq-adapter/test/TmpPostgres.hs` supplies `withPgmqDb`, `withTestFixture`, and `runPgmqSession`; it starts ephemeral PostgreSQL and installs the schema with `pgmq-migration`. `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs` already runs real handlers through `runApp`, checks application reasons, retries discarded commit confirmations, races finalizers, and checks failed moves. Reuse that style. `shibuya-pgmq-adapter/test/Main.hs` explicitly registers specs, and the Cabal test component compiles modules from both `src` and `test`; new modules must appear in its `other-modules` as well as the library's appropriate module list.

`shibuya-pgmq-adapter-bench/bench-dlq/Main.hs` already fully evaluates JSON encoding for legacy and current dual-written payloads, but does not exercise the proposed queue-aware helper. `shibuya-pgmq-adapter-bench/bench/Bench/Throughput.hs` measures raw queue operations and includes queue setup in some timed actions; its timings cannot stand in for adapter worker regression evidence. `shibuya-pgmq-adapter-bench/app/Endurance.hs` supplies a real adapter lifecycle and runtime-memory sampling pattern. Extend these assets with a focused performance runner rather than interpreting the historical numbers in `shibuya-pgmq-adapter-bench/README.md` as a baseline.

Upstream discovery used Mori. `mori://shinzui/pgmq-hs/packages/pgmq-hasql` owns `Pgmq.Hasql.Sessions.peekMessages`, `lookupMessage`, their argument records, and `Pgmq.Hasql.Statements.Inspection`. Its `PeekMessages` has `unvalidatedQueueName :: Text`, `afterMessageId :: Maybe MessageId`, and `limit :: Int32`; `LookupMessage` has the name and message ID. The statement layer exposes `formatTableName`, `quoteIdentifier`, `peekStatement`, and `lookupStatement` for composing transactions. Resolve physical names on the server and quote identifiers using these helpers. Never interpolate input text into SQL. The upstream guide is `mori://shinzui/pgmq-hs/docs/queue-inspection`; detailed source/design references are project `mori://shinzui/pgmq-hs`, paths `pgmq-hasql/src/Pgmq/Hasql/Statements/Inspection.hs` and `docs/design/019-non-destructive-inspection-reads.md` (artifact-level URIs pending).

The [Hackage version registry](https://hackage.haskell.org/package/pgmq-hasql.json), [published Cabal file](https://hackage.haskell.org/package/pgmq-hasql-0.7.0.0/pgmq-hasql.cabal), and upstream `v0.7.0.0` tag were rechecked on 2026-10-26. The released 0.7.0.0 family contains inspection and is already required in library/test bounds. Use the normal released-dependency project; no upstream source override is needed. The upstream implementation plan remains `mori://shinzui/pgmq-hs/plans/27-add-non-destructive-peek-archive-and-lookup-reads-across-the-pgmq-layers`.

The originating initiative's ownership decision, `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`, puts queue mechanics in the queue library and DLQ meaning in the adapter. Its packaging decision, `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`, keeps HTTP/WebSocket dependencies in optional sister packages. Its control-plane decision, `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7`, requires mutation gates in the owning backend. These records were read after registry discovery, and their canonical handles resolve with `mori path`. No transport work is needed to satisfy them here.

## Plan of Work


### M1 — Dependency baseline and first real roundtrip


Recheck Hackage and upstream tags for the first released version that actually contains inspection. Read its sources through Mori before changing both library and test dependency lower bounds in `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`. Update only related dependency constraints when required by the released family. Build with that release and record the version and tag. If it is still unreleased, record the prerequisite and continue only independent work or a clearly temporary local-source integration proof; do not copy the upstream implementation into this repository or publish a dependency release as part of this plan.

Before feature edits, preserve baseline commit `e06e64b268055aca4eff78caabd1b0eb73aa1cd1`. Add benchmark-only instrumentation that compiles against its existing public worker API and can be applied unchanged to both baseline and candidate in temporary source directories, without changing branches or production code in the baseline. Record compiler, optimization and runtime flags, dependency resolutions, PostgreSQL version/settings, hardware, fixture sizes, pool sizes, and the instrumentation diff. Capture the existing dependency baseline, then the same adapter source with the selected released dependencies to separate dependency-update costs from feature costs. The final candidate must pass against the original dependency baseline as well as the matched-dependency control; a dependency upgrade cannot silently absorb a regression. If the old adapter needs compatibility edits for the matched control, retain the minimal diff and explain it; the original baseline remains mandatory.

Add `mkDlqPayloadForQueue :: QueueName -> Pgmq.Message -> DeadLetterReason -> Bool -> Pgmq.MessageBody` to `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs`. It adds `original_queue` using `queueNameToText` to the existing payload without changing `mkDlqPayload`'s existing output or type. Use the new helper in `deadLetterTransactionally` for both direct and topic targets, including automatic dead-lettering. Keep `includeMetadata`'s existing meaning for the other fields. Add exact-object tests for the new helper in `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConvertSpec.hs` and update producer assertions that see real adapter output.

Create public `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/DeadLetter.hs` and private `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/DeadLetter/Internal.hs`, plus `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/DeadLetterSpec.hs`. Implement the minimal decoded-entry path and wire the spec into Cabal and `test/Main.hs`. First prove one real `ApplicationFailure` passing through a handler, DLQ write, and the new public browse function. Assert exact application code, text detail represented as `Aeson.Value`, source queue, original delivery count, original payload, and DLQ enqueue time. This is the early integration proof; do not expand every historical variant before it works. M1 completes only with this proof on a released dependency baseline.

### M2 — Complete non-destructive browse and fetch


Implement the API contract below. Keep inspection configuration separate from `PgmqAdapterConfig` so worker-only adopters acquire no new mandatory record fields. Validate configuration before issuing queries: registrations must be unique by DLQ, have nonempty distinct allowed source queues, and exclude the DLQ itself. Add a helper deriving a registration from a direct adapter configuration; reject absent/topic targets in that helper and accept explicit physical registrations for topic-bound queues. Nothing automatically discovers or creates queues.

A page request uses an exclusive cursor bound to its DLQ and a positive limit, default 50 and maximum 500. Reject invalid limits or a cursor for another DLQ before database access. Fetch `limit + 1` rows through upstream statements, return at most `limit`, and set the next cursor to the last returned row only when the extra row exists. Preserve raw order, including malformed entries, so corrupt rows cannot prevent progress or disappear silently. Return an inspectable item containing the raw `Pgmq.Message` plus `Either DlqDecodeError DeadLetterEntry`; fetch uses the same item, with a typed `EntryNotFound` only for absence. Database failures remain typed runtime errors, not empty pages or not-found responses.

Decode `dead_letter_reason_code` and `dead_letter_reason_detail` as the authoritative pair, preserving detail as arbitrary `Aeson.Value` without converting it to text. A missing structured field or wrong code type is a malformed envelope when either structured key exists. Only when both are absent, support the legacy rendered string by splitting the first `": "` into a textual code and string detail; a delimiter-free reason has null detail. Mark this representation as legacy so callers know it was inferred. Preserve built-in underscore codes rather than incorrectly requiring every code to be an application dotted code. Missing `original_message` is an error; present JSON null is a valid original payload. Optional metadata missing on old rows is unknown, whereas wrong-type metadata is malformed.

Resolve `original_queue` against the registration. An explicit queue must parse and be allowed. If absent, use the sole allowed source as an explicitly marked configuration fallback; with multiple allowed sources, show an unresolved source and refuse redrive. Do not guess based on naming conventions. Keep the original source read count (`Maybe Int64`) separate from the current DLQ row's read count (`Int64`), and the original enqueue time separate from the DLQ enqueue time. Metadata-disabled entries have no original count, and must not display zero as if measured.

Use a host-supplied pool reserved for administration, connected to the same database as the queues. Add finite statement and lock timeouts (defaults 5000 ms and 1000 ms; positive values validated) scoped to each transaction so settings do not leak through pooled connections. Reads use read-only transactions; the private module composes the upstream statements after server-side table-name resolution. A bounded row count is not a bound on JSON bytes or database scan work. Document each page as a moving view rather than a snapshot or durable replay cursor; restarting at the first page discovers lower IDs committed late.

M2 is accepted when page and fetch tests cover empty, boundary, multipage, malformed, metadata-disabled, and legacy/dual-written/structured-only envelopes; raw before/after queries show identical `vt`, `read_ct`, `last_read_at`, payloads, headers, and row counts, including invisible messages. Also exercise registered shared/topic DLQs with two sources and show that another queue cannot be inspected through this API unless registered.

### M3 — Gated atomic redrive


Check `redriveEnabled` first on every call, before database access. Disabled returns a structured `RedriveDisabled` error. Enabled calls validate the DLQ registration and then start one `ReadCommitted` write transaction. Resolve the table through upstream `formatTableName`, read the selected row with `SELECT ... FOR UPDATE`, and decode and authorize that locked row inside the transaction. Add the narrow lock-bearing statement in the adapter's private module using upstream `quoteIdentifier` and `Pgmq.Hasql.Decoders.messageDecoder`; this is adapter transaction composition, not a replacement general inspection API. Use the decoder's seven columns in their documented order (`msg_id`, `read_ct`, `enqueued_at`, `last_read_at`, `vt`, `message`, `headers`). No row means `AlreadyAbsent`.

For a valid row with an authorized source, delete via `Msg.deleteMessage`, inspect its Boolean result, and send only if the delete claimed the row. Send `original_message`, never the DLQ wrapper, directly to the resolved source using `Msg.sendMessage` or `Msg.sendMessageWithHeaders`, with no delay. Prefer saved `original_headers` when present, including explicit null; when the field is absent use the DLQ row's headers, preserving FIFO grouping and documenting that its trace context may have been replaced by dead-letter routing. Preserve the distinction between missing and explicitly null headers in the internal decoder. Return the newly assigned source message ID only on a confirmed successful transaction. Redrive resets queue delivery count and enqueue time, uses a new queue-local message ID, and adds the message at the queue tail; it does not restore the original FIFO position.

Reject malformed envelopes, unknown/ambiguous sources, and unregistered targets without deleting anything. PostgreSQL rollback must restore the DLQ entry if sending fails. Do not create a missing source queue automatically. Convert pool failures through the existing `fromUsageError` runtime error mapping and expose them through `DlqError`. Let cancellation unwind the transaction; do not catch asynchronous exceptions as successful absence. Bounded transient retry may reuse `retryingTransient` semantics, but never retry an isolated send outside the transaction. Caller retry of the complete operation must be safe even after an unknown commit outcome.

M3 is accepted with real-database tests for the default gate, explicit enablement, exact payload/header restoration, sequential repeat, two independent concurrent calls, a discarded success response followed by a fresh call, and a missing source queue that forces rollback. Malformed and ambiguous-source attempts remain browsable and unmodified. A repeated call may return `AlreadyAbsent`; it must never insert a second source row. Topic tests establish the stated per-entry boundary and do not claim cross-copy deduplication.

### M4 — Performance gates, consumer guidance, and final checks


Extend `shibuya-pgmq-adapter-bench/bench-dlq/Main.hs` with paired current/queue-aware serialization cases for both metadata modes, all existing reasons, and 100-byte, 10-KB, and 100-KB original bodies. Add a focused runner under `shibuya-pgmq-adapter-bench/app/DlqPerformance.hs`, register it in `shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal`, and add `scripts/check-dlq-performance.py` to orchestrate baseline/candidate builds and enforce the gates below. Keep shared worker measurements independent of the new administration module so identical instrumentation builds against the old adapter; candidate-only administration scenarios can use a separate module. Use Mori before adopting benchmark or statistics APIs.

The script provisions only disposable local PostgreSQL databases and isolated source/build directories, warms fixtures, runs paired samples, retains raw measurements and query plans, and exits nonzero on a failed or inconclusive gate. Never connect it to a production database. Exclude queue creation, seeding, schema installation, compilation, and cleanup from timed worker operations. Include pool acquisition, decoding, transaction completion, and retries in public API latency. Force encoded bytes and decoded results so lazy evaluation cannot move work outside the measurement. A handler completing is not an acknowledgement measurement: time finalization through confirmed commit and separately count committed worker completions.

Record a concise results report at `docs/performance/9-dlq-browse-and-redrive.md` with exact commands, environment, commit/dependency identities, per-case ratios, confidence bounds, and paths to retained raw artifacts. Extend `shibuya-pgmq-adapter-bench/README.md` with reproduction instructions. M4 requires every applicable performance gate, not just the correctness suite. Diagnose failures and rerun affected comparisons after fixes; do not disable safety checks, change workload rates, pool sizes, or page limits to obtain a passing run without recording and approving a scope change.


Extend `docs/user/pgmq-dead-letter-queues.md` with a compilable embedding example, registration and source-resolution rules, paging limits, mixed-history behavior, separate pool configuration, and the default-off gate. Explain that enabling the gate is a host configuration choice, not an authentication system, and that host transports must enforce their own caller permissions. Correct its payload example for new `original_queue` writes without removing the compatibility fields. Document recovery after an ambiguous commit and distinguish exactly one redrive insertion from the adapter's at-least-once handler delivery.

Update `README.md`, root `CHANGELOG.md`, package `shibuya-pgmq-adapter/CHANGELOG.md`, and `docs/capabilities/dead-letter-routing.md` with the new public API and tested limits. Update IR-3's status and evidence only after acceptance. Maintain affected OKF logs using `okf log add --help` and the repository profiles; do not label unshipped work as released or fabricate a release version. Add an ordinary Markdown ADR in `docs/adr/` recording the gate, explicit queue mapping, retention compatibility, transaction claim, and topic-copy boundary, linking ADR 0001. No schema migration or receipt table is required.

Run final correctness and performance checks below with the released dependency set and no temporary dependency override. Record concise evidence, triage friction recorded during implementation, and fill Outcomes & Retrospective. Publishing/tagging releases is not part of this plan's completion criteria.

## Concrete Steps


All repository commands run from the root of this checkout, `shibuya-pgmq-adapter`. Use Mori for dependency discovery; never inspect `/nix/store` or search the filesystem root. Establish prerequisite evidence with:

```bash
mori registry search pgmq
mori registry show shinzui/pgmq-hs --full
mori registry docs shinzui/pgmq-hs
curl -fsSL https://hackage.haskell.org/package/pgmq-hasql.json
git ls-remote --tags https://github.com/shinzui/pgmq-hs.git
```

The current released minimum is `0.7.0.0`, including inspection. Use the repository's normal `cabal.project` with no local upstream override. The former temporary-source reproduction is retired. After removing the transitional flag, the focused suite below must execute the administration examples; selecting zero examples is not evidence.

After adding the public API/spec registration, run the focused tests with the spec's top-level description set to `Dead-letter administration`:

```bash
nix develop --no-write-lock-file -c cabal test shibuya-pgmq-adapter-test --enable-tests --test-show-details=direct --test-options='--match "Dead-letter administration"'
```

Expected output names actual executed examples for producer-to-browse, non-destructive pagination/fetch, and redrive as they are implemented, finishing with zero failures. A run selecting zero tests is not evidence. PostgreSQL executables must be available; the Nix shell supplies them. The tests install PGMQ in their ephemeral databases and need no production connection, running application, or external service started by `just process-up`.

Complete the performance runner and acceptance script described in M4 before running the following commands; only the original-worker capture script exists at this resume checkpoint. Its `--baseline-ref` selects the preserved pre-feature source, and its default matrix includes all performance cases below, with the original and matched dependency controls. `--output` is an untracked artifact directory, not a database connection. The script must fail on omitted cases or missing baseline evidence, run children using argument arrays, and stop its own temporary database processes on exit:

```bash
nix develop --no-write-lock-file -c cabal bench shibuya-pgmq-adapter-bench:bench:dlq-payload-bench
nix develop --no-write-lock-file -c python3 scripts/check-dlq-performance.py --baseline-ref e06e64b268055aca4eff78caabd1b0eb73aa1cd1 --pairs 7 --warmup-seconds 10 --sample-seconds 60 --output .dev/dlq-performance
```

Expected final script output is `DLQ-PERFORMANCE: PASS` only after every required comparison is accepted, with a machine-readable result for each case. `FAIL` and `INCONCLUSIVE` both exit nonzero. The serialization benchmark alone is diagnostic and cannot close M4. Preserve evidence from the final implementation candidate; rerun when a source or dependency change invalidates it.

At the final coherent boundary run:

```bash
nix develop --no-write-lock-file -c cabal build all --enable-tests --builddir=dist-dlq-release
nix develop --no-write-lock-file -c cabal test shibuya-pgmq-adapter-test --enable-tests --builddir=dist-dlq-release --test-show-details=direct
nix develop --no-write-lock-file -c cabal haddock shibuya-pgmq-adapter --builddir=dist-dlq-release
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
git diff --check
```

Build, full tests, documentation build, performance gates, changed-bundle validation, and whitespace checks must pass. The dedicated build directory avoids stale incremental artifacts after the dependency/optimization transition; it changes no dependency overrides or acceptance. Run the repository formatter on changed Haskell/Cabal files as configured in `nix/treefmt.nix`; avoid unrelated formatting churn. If `mori validate` from `just check-capabilities` has an unrelated pre-existing failure, record its exact diagnostic separately rather than silently claiming that aggregate check passed or expanding scope to registry migration.

Commits during implementation stay on the current branch, use Conventional Commits, and carry both trailers:

```text
ExecPlan: docs/plans/9-expose-adapter-managed-dead-letter-queue-browse-and-redrive.md
Intention: intention_01m5v5br8qewxvh359b0hpw6cw
```

## Validation and Acceptance


The handler scenario must use the released `ApplicationFailure code text` constructor: an application code such as `orders.validation.failed` and a Unicode detail string must survive the real adapter, browse, and fetch unchanged. A separate raw-row fixture carries nested object/array detail under `dead_letter_reason_detail` to prove the read model preserves arbitrary JSON. Do not claim the current handler API can emit arbitrary detail objects or parse JSON-looking strings into objects. Producer support for richer detail is separate work.

Browse three ordered rows with page size two; observe two entries and a cursor, then the last entry and no cursor. Deleting an earlier row must not shift the next page. Reject zero, negative, excessive limits and queue-mismatched cursors. Compare raw row state before/after repeated list and fetch calls, including invisible and malformed rows. Fetching an absent ID returns `EntryNotFound`, while missing tables or connection failures remain database errors.

Default redrive must return `RedriveDisabled` with raw queue state unchanged. Enabled redrive must return a source ID, remove the selected DLQ row, and leave exactly one new source row containing the original body and expected headers. Observe its initial `read_ct = 0` non-destructively, then consume it once and verify ordinary handler input rather than the wrapper. Repeat and race fresh calls for the same DLQ identity; observe a single source insertion in all cases. Discard a confirmed response and retry to test the durable guard, while describing this accurately as response-discard simulation rather than injected network loss.

Force a send failure by targeting a registered but absent source queue: the transaction must fail and the DLQ row must remain byte-for-byte unchanged. Recreate that source in the test fixture and retry successfully. Test wrong-source metadata, ambiguous historical sources, missing original payload, null original payload, and both metadata modes. Explicit original null headers must not be replaced by DLQ trace headers. Concurrent topic fan-out copies are separately addressable; the docs and tests must make clear that redriving two distinct copies can produce two source messages.

The complete suite must retain existing acknowledgement, retry, FIFO, automatic dead-letter, trace propagation, and cancellation behavior. The documentation example must compile against only the public exports. Completion requires all four milestones with actual database and performance evidence. A live feed, HTTP integration, and cross-project release remain outside acceptance.

### Performance acceptance


Run comparisons sequentially on the same otherwise idle machine and PostgreSQL configuration, using optimized builds, identical runtime capabilities, fixed payloads, and identical worker pool sizes. Alternate baseline/candidate order over at least seven pairs, with ten seconds of warmup and at least sixty seconds of measured work per run. For short encoding cases, batch enough forced encodings to exceed timer resolution and retain per-operation timing and allocation. Require at least 1,000 worker latency observations per run; extend the duration consistently if needed. Report throughput as committed original messages per second and p95 latency as the duration below which 95% of measured operations fall. Do not average percentiles across different workloads or count redriven background messages as additional original-work throughput.

For each case, report all paired ratios and their median. Bootstrap the pairs with 10,000 resamples and a fixed recorded random seed, using the 95th percentile of resampled medians as the one-sided upper confidence bound for cost ratios; for throughput use baseline throughput divided by candidate throughput. For limits combining a relative and an absolute allowance, divide each measured candidate cost by its allowed control cost before resampling and require an upper bound at most one. A gate passes only when that upper bound is within its stated limit. This is a reproducibility convention, not proof for every environment. Insufficient observations, unstable measurements, a failed worker, missing case, or a confidence bound crossing the budget is unresolved acceptance. Retain all runs; do not keep rerunning until a favorable subset passes.

**Worker behavior with administration idle.** Use three representative real `pgmqAdapter` `AckOk` scenarios: one ordinary worker with batch size one and 100-byte bodies; four ordinary workers with batch size fifty and 10-KB bodies; and four grouped-head FIFO workers with batch size fifty, 10-KB bodies, and 100 evenly populated groups. Keep all settings fixed between controls. Add four all-dead-letter scenarios with four ordinary workers, batch size fifty, and 1-KB bodies: direct routing and a two-destination topic route, each with metadata enabled and disabled. This is a defined seven-scenario matrix, not the Cartesian product of every setting. Preseed enough messages outside the timed region to keep workers supplied throughout warmup and measurement; queue depletion makes a run inconclusive. The candidate must retain at least 95% of baseline committed throughput (cost-ratio bound at most `1 / 0.95`), increase p95 finalization latency by no more than 10%, and increase allocated bytes per successfully acknowledged message by no more than 5%. For dead-letter writes, apply the same throughput/latency limits and the encoding allocation allowance below instead of the 5% `AckOk` allocation limit. Run the seven candidate scenarios with an initialized-but-idle administration handle and additionally run the four-ordinary-worker `AckOk` scenario without a handle. Verify that constructing the handle does not start polling or add database calls to worker delivery/finalization.

**DLQ payload costs.** Compare `mkDlqPayloadForQueue` with the existing dual-written `mkDlqPayload`, not the much smaller legacy-only representation. Across the M4 serialization matrix, allow at most 10% more encoding time or 0.5 microseconds more per operation, whichever allowance is larger, and at most `2048 + 4 * sourceFieldBytes` additional allocated bytes per operation. Here `sourceFieldBytes` is the exact compact-JSON increase caused solely by `original_queue`, including its key, JSON-encoded queue value, colon, and separator. Assert that encoded byte growth equals that field's contribution and does not grow with the original body or detail size; report PostgreSQL `pg_column_size(message)` separately because JSONB storage has a different representation. These explicit allowances accommodate adding the required field while detecting extra full-body traversals/copies. Measure allocations in a dedicated repeated-encoding loop with runtime statistics; whole-process totals including setup are not evidence.

**Shared database under operator load.** Use four real workers with four worker connections and a separate two-connection administrative pool against the same database. Compare candidate workers without administrative traffic to candidate workers while a fixed-rate driver requests five 50-entry browse pages, five fetches, and one redrive per second, with at most two administrative calls in flight. Use a 100,000-row DLQ, 1-KB bodies, and redrive to a source actively consumed by the worker workload; distinguish background messages by ID. Exercise batch sizes one and fifty, ordinary and grouped-head FIFO workers. The loaded run must retain at least 95% of idle original-work throughput, increase p95 finalization latency by no more than 10%, and have no worker errors or acknowledgement timeouts. Report scheduled, started, completed, and failed administrative calls plus request latency from scheduled arrival, so a slow service cannot hide cost by issuing less work. Require at least 99% of scheduled administration calls to complete successfully during measurement plus a five-second drain, with no accumulating backlog. Empty pages, absent fetches, or `AlreadyAbsent` redrives cannot substitute for seeded successful operations in this workload. Separately report process/database CPU and I/O counters where available. Separate connections do not isolate database CPU, I/O, or locks, which is why this comparison is required.

**Large queues, reads, and retention.** Seed ordinary and unlogged DLQs at 100,000 and 1,000,000 rows with 100-byte bodies. Measure first, middle, and near-tail pages at limits 50 and 500 and fetches at matching IDs; also use a 1,000-row fixture with 100-KB bodies to exercise large pages without creating an unnecessarily huge database. Compare the adapter API with upstream inspection on the identical rows, transaction/deadline settings, and pool sizes, fully consuming both results. Adapter p95 browse/fetch latency must be at most twice the corresponding raw-read p95 plus five milliseconds; raw reads are a control for new functionality, not a replacement for the old-worker baseline. At fixed page size and body size, increasing depth tenfold must increase p95 latency by no more than 50%. Retain `EXPLAIN (ANALYZE, BUFFERS)` for actual underlying page and lookup queries after fixture analysis: ordinary/unlogged queues must use message-ID index access without a full-table sort or scan. Correctness, timeout, and malformed-row tests still apply. If partitioned queues are advertised as performance-validated, run their equivalent fixtures and record their plans separately; otherwise explicitly state that the measured budget covers ordinary/unlogged queues, and do not generalize it to partitioned layouts.

Repeat the fixed-size large-payload page workload for five measured minutes, discard results after each call, and sample live heap after major collection outside timed requests. After the first minute, the median retained heap in the final minute must exceed that of the second minute by no more than the larger of 5% or 8 MiB. Record peak residency and allocations per page as well. This checks for accidentally retained page history; it does not impose a payload-byte limit on the public API. Redrive's new operation has no old adapter equivalent: report its p50/p95 latency and achieved rate under the fixed operator workload, while its effect on existing workers and its success rate are gated above.

## Idempotence and Recovery


No production rows are rewritten or migrated during deployment. New envelopes gain source identity; old envelopes remain readable. Rolling back to the existing writer stops adding that field, so keep the historical mapping fallback available. Keep the redrive gate disabled during rollout until the host has supplied correct registrations and separately provisioned administrative connection capacity.

Row locks and delete/send in one transaction serialize competing redrives. Before commit, a failure restores the DLQ row; after commit, retry sees it absent and sends nothing. IDs reused by dropping and recreating a queue are outside the identity lifetime: do not replay old operator requests across queue recreation. Missing-row outcomes cannot distinguish a prior successful redrive from another actor's deletion. Hosts resolve uncertainty by browsing/fetching and checking their normal source processing records, not by resending the stored payload independently.

Tests use fresh ephemeral databases and unique fixture names, so rerunning them does not touch application queues. Do not use `just reset-database` for this work. Keep temporary dependency projects untracked and remove only the files created for this plan when switching back to released dependencies. Retain failure evidence and rerun the relevant transaction scenario after a fix before repeating the final suite.

Performance fixtures also live only in disposable databases. Recreate or restore identical fixture state between paired runs so redrive, deletion, cache warming, or queue depletion does not change the comparison. Benchmark orchestration must clean up only its own directories/processes and preserve measurement artifacts after failure. Keep the baseline source and dependency identities fixed across optimization attempts. A failing performance gate blocks completion; it is not permission to weaken correctness or silently relax the stated budgets.

## Interfaces and Dependencies


Expose the following operations from `Shibuya.Adapter.Pgmq.DeadLetter`; export useful types and Haddock documentation from that module rather than requiring callers to import internals. The public API uses `IO` with explicit `Either` outcomes, so a host can embed it without starting a worker or providing tracing effects:

```haskell
mkDeadLetterAdmin
  :: Pool.Pool -> DeadLetterAdminConfig
  -> Either DlqConfigError DeadLetterAdmin

browseDeadLetters
  :: DeadLetterAdmin -> QueueName -> DlqPageRequest
  -> IO (Either DlqError DeadLetterPage)

fetchDeadLetter
  :: DeadLetterAdmin -> QueueName -> MessageId
  -> IO (Either DlqError DeadLetterItem)

redriveDeadLetter
  :: DeadLetterAdmin -> QueueName -> MessageId
  -> IO (Either DlqError RedriveOutcome)

data RedriveOutcome
  = Redriven MessageId
  | AlreadyAbsent
```

`DeadLetterAdmin` is opaque and retains validated configuration and a borrowed pool; it does not create or close that pool. `DeadLetterAdminConfig` holds registrations, `redriveEnabled`, and finite query/lock deadlines. Provide a default constructor taking registrations and setting redrive to false and deadlines to the defaults above. `DlqPageRequest` holds a page limit and optional queue-bound cursor. `DeadLetterPage` holds a vector of `DeadLetterItem` and optional next cursor. `DeadLetterItem` retains the raw message, its DLQ identity, and either decoded fields or a structured decode error identifying the invalid field.

`DeadLetterEntry` exposes original JSON payload, textual reason code, JSON reason detail, reason representation (structured or legacy), resolved source and resolution basis (payload, configured fallback, or unavailable), optional original ID/count/timestamps/headers, and current DLQ ID/count/timestamps. Keep missing versus null original headers internally distinguishable for redrive. `DlqError` distinguishes disabled mutation, unknown managed DLQ, invalid page request, entry not found, malformed envelope, unresolved/disallowed source, and `PgmqRuntimeError`. `DlqConfigError` distinguishes invalid registrations and deadlines. Do not flatten all failures into text or expose an arbitrary destination argument on redrive.

Use existing Aeson, Hasql, Hasql pool/transaction, PGMQ core/hasql/effectful runtime-error mapping, text, time, and vector dependencies. Do not add `pgmq-inspect` or any web/server dependency. The upstream read requirement is `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-1`; its inspection API is available in the released 0.7.0.0 dependency family. This is a standalone plan, not a child MasterPlan. The intention in frontmatter is authoritative for future implementation sessions.

Revision note, 2026-10-25: added required baseline capture, numeric performance budgets, shared-database load and large-queue comparisons, memory/encoding checks, reproducible runner commands, and retained evidence after the user requested performance-regression protection. Updated M1/M4 and removed the previous exclusion of benchmark thresholds. No performance measurements have been run by this planning revision.

Revision note, 2026-10-26: refreshed dependency discovery after the 0.7.0.0 release and adoption; resume unflagged acceptance and the original numeric performance gates without temporary dependency overrides. Historical checkpoints above describe their original evidence, not current release availability.

Measurement checkpoint: the first full attempt at `.dev/dlq-release-25cb519/` was interrupted after eight completed samples to replace payload-marker classification with the required source-ID boundary in common instrumentation. Retain those diagnostic samples; restart the complete experiment with identical corrected instrumentation on both controls and candidate. No passing numeric result is claimed from this interrupted attempt.
