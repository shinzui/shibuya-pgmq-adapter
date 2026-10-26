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
---


# Expose adapter-managed dead-letter queue browse and redrive


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Follow `agents/skills/exec-plan/PLANS.md`, `ADR.md`, and `FRICTION.md` in that skill directory during implementation. This plan implements [IR-3](../improvement-requests/expose-dead-letter-queue-browse-and-redrive-for-adapter-managed-dlqs.md).

## Purpose / Big Picture


An operator will be able to inspect messages in an adapter-managed dead-letter queue (DLQ), see why each failed, fetch one by its queue-local message ID, and explicitly return one to its original queue after correcting the cause. Inspection must not lease messages or change delivery counters. Redrive means atomically removing a chosen DLQ entry and inserting its original payload into the source queue; it is disabled unless the host enables it.

Deliver an in-process Haskell API and real PostgreSQL tests. HTTP endpoints, a browser UI, a live feed, bulk redrive, and archive recovery are outside this plan. A host can later expose these operations through its own transport. The primary demonstration is a real handler returning an application-defined `AckDeadLetter`, followed by browse, fetch, a refused default redrive, and an enabled redrive that creates exactly one source message despite retry and concurrency.

## Progress


- [ ] M1 — Establish a supported dependency baseline and prove the public producer-to-browse path against real PostgreSQL, including source identity and exact reason fields.
- [ ] M2 — Complete bounded browse and fetch, mixed-history decoding, explicit managed-queue registration, and tests proving reads do not modify rows.
- [ ] M3 — Deliver disabled-by-default transactional redrive with typed outcomes, rollback, retry, and concurrent-call evidence.
- [ ] M4 — Complete operator documentation, durable architecture decisions, capability/request records, and the final released-dependency build and test checks.

Planning handoff, 2026-10-25: implementation has not begun. The required upstream inspection API exists in its working tree but is unreleased. M1's released-dependency prerequisite is open; pure decoder/configuration work can proceed independently. Do not report this plan complete with only a local dependency override.

## Surprises & Discoveries


## Decision Log


2026-10-25 — Implement the minimum in-process API in the adapter package and defer transports and the optional feed. The request explicitly permits this scope, and no web dependencies are necessary for adapter semantics.

2026-10-25 — Consume upstream non-destructive inspection statements once released; do not recreate a general queue browser here. A temporary local dependency project may prove the integration before release, but is not the production dependency solution.

2026-10-25 — Add `original_queue` to new adapter-produced DLQ envelopes, independently of `includeMetadata`, while preserving the existing `mkDlqPayload` signature and reason fields. The source identity is needed for shared/topic DLQs and safe redrive; historical rows cannot recover it from the envelope alone. Missing original delivery counts remain unknown rather than using the DLQ row's own count.

2026-10-25 — Require a host-defined mapping from each managed physical DLQ to its allowed source queues. The default configuration disables redrive; a payload's queue name cannot grant permission to send to an arbitrary queue. Reject source/DLQ self-mappings. Topic destinations must be registered explicitly rather than guessed from a routing key.

2026-10-25 — Define idempotence per physical DLQ queue and message ID, using the row as the durable claim. Returning `AlreadyAbsent` after a retry is honest: without a receipt table, absence cannot prove who removed a row. Distinct topic fan-out copies are distinct entries and can each be redriven; global deduplication across them is outside this guarantee.

## Outcomes & Retrospective


## Context and Orientation


The adapter is a library, currently version `0.17.0.0` in `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`. PGMQ is PostgreSQL-backed message queuing. A read leases a message by changing its visibility deadline (`vt`) and incrementing `read_ct`; browsing must instead use ordinary observation without leasing. IDs belong to a queue, so every fetch, cursor, and redrive must retain the DLQ identity.

`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs` defines `PgmqAdapterConfig`, `DeadLetterConfig`, and `DeadLetterTarget`. A target is either `DirectQueue QueueName` or `TopicRoute RoutingKey`; topics may copy one failure to several physical queues. With no target configured, dead-lettering archives rather than creating a DLQ row. Archives are not managed DLQs for this feature.

`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` contains public `mkDlqPayload`. Its actual contract differs from the request's prose: it currently writes `original_message`, the legacy rendered string `dead_letter_reason`, the stable string `dead_letter_reason_code`, and `dead_letter_reason_detail`. Detail is currently a JSON string or null because the core's producer accepts text, not arbitrary JSON. `includeMetadata` additionally writes original ID, enqueue time, last-read time, `read_count`, and original headers. It does not write the original queue. Preserve all reason fields; the separately deferred [Plan 6](6-remove-the-legacy-dead-letter-reason-field-after-structured-rollout.md) must not be implemented here. [Plan 5](5-preserve-structured-dead-letter-reasons-in-pgmq-dlq-payloads.md) established the structured code/detail fields this reader consumes.

`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` implements `deadLetterTransactionally`: inside one `ReadCommitted` write transaction, delete the source row and send only when deletion succeeds. Sending failure rolls back the deletion. [ADR 0001](../adr/0001-idempotent-dead-letter-moves.md) requires this durable claim and documents why an in-memory flag alone cannot prevent duplicates after a lost commit response. Apply the same principle in the reverse direction. The local ADR directory uses ordinary Markdown, not a profiled OKF bundle; `mori show --full` currently declares no ADR bundle. Preserve that convention when recording redrive's gate and guarantees.

`shibuya-pgmq-adapter/test/TmpPostgres.hs` supplies `withPgmqDb`, `withTestFixture`, and `runPgmqSession`; it starts ephemeral PostgreSQL and installs the schema with `pgmq-migration`. `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs` already runs real handlers through `runApp`, checks application reasons, retries discarded commit confirmations, races finalizers, and checks failed moves. Reuse that style. `shibuya-pgmq-adapter/test/Main.hs` explicitly registers specs, and the Cabal test component compiles modules from both `src` and `test`; new modules must appear in its `other-modules` as well as the library's appropriate module list.

Upstream discovery used Mori. `mori://shinzui/pgmq-hs/packages/pgmq-hasql` owns `Pgmq.Hasql.Sessions.peekMessages`, `lookupMessage`, their argument records, and `Pgmq.Hasql.Statements.Inspection`. Its `PeekMessages` has `unvalidatedQueueName :: Text`, `afterMessageId :: Maybe MessageId`, and `limit :: Int32`; `LookupMessage` has the name and message ID. The statement layer exposes `formatTableName`, `quoteIdentifier`, `peekStatement`, and `lookupStatement` for composing transactions. Resolve physical names on the server and quote identifiers using these helpers. Never interpolate input text into SQL. The upstream guide is `mori://shinzui/pgmq-hs/docs/queue-inspection`; detailed source/design references are project `mori://shinzui/pgmq-hs`, paths `pgmq-hasql/src/Pgmq/Hasql/Statements/Inspection.hs` and `docs/design/019-non-destructive-inspection-reads.md` (artifact-level URIs pending).

On 2026-10-25, the [Hackage version registry](https://hackage.haskell.org/package/pgmq-hasql.json) and [upstream tags](https://github.com/shinzui/pgmq-hs/tags) both identify `0.6.1.1` as the latest release. Its published Cabal file does not expose the inspection module. The local upstream checkout at commit `5cb33cfd600766f1fb6f1856c78c9a5c92d12ce7` places inspection under Unreleased. The upstream implementation plan is `mori://shinzui/pgmq-hs/plans/27-add-non-destructive-peek-archive-and-lookup-reads-across-the-pgmq-layers`; current `mori path` resolution fails, so locate its project through the registry rather than replacing the reference with a bare external path. Do not assume `pgmq-hasql ^>=0.6` guarantees these functions, or invent a future release number.

The originating initiative's ownership decision, `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`, puts queue mechanics in the queue library and DLQ meaning in the adapter. Its packaging decision, `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`, keeps HTTP/WebSocket dependencies in optional sister packages. Its control-plane decision, `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7`, requires mutation gates in the owning backend. These records were read after registry discovery, and their canonical handles resolve with `mori path`. No transport work is needed to satisfy them here.

## Plan of Work


### M1 — Dependency baseline and first real roundtrip


Recheck Hackage and upstream tags for the first released version that actually contains inspection. Read its sources through Mori before changing both library and test dependency lower bounds in `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`. Update only related dependency constraints when required by the released family. Build with that release and record the version and tag. If it is still unreleased, record the prerequisite and continue only independent work or a clearly temporary local-source integration proof; do not copy the upstream implementation into this repository or publish a dependency release as part of this plan.

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

### M4 — Consumer guidance and final checks


Extend `docs/user/pgmq-dead-letter-queues.md` with a compilable embedding example, registration and source-resolution rules, paging limits, mixed-history behavior, separate pool configuration, and the default-off gate. Explain that enabling the gate is a host configuration choice, not an authentication system, and that host transports must enforce their own caller permissions. Correct its payload example for new `original_queue` writes without removing the compatibility fields. Document recovery after an ambiguous commit and distinguish exactly one redrive insertion from the adapter's at-least-once handler delivery.

Update `README.md`, root `CHANGELOG.md`, package `shibuya-pgmq-adapter/CHANGELOG.md`, and `docs/capabilities/dead-letter-routing.md` with the new public API and tested limits. Update IR-3's status and evidence only after acceptance. Maintain affected OKF logs using `okf log add --help` and the repository profiles; do not label unshipped work as released or fabricate a release version. Add an ordinary Markdown ADR in `docs/adr/` recording the gate, explicit queue mapping, retention compatibility, transaction claim, and topic-copy boundary, linking ADR 0001. No schema migration or receipt table is required.

Run final checks below with the released dependency set and no temporary override. Record concise evidence, triage friction recorded during implementation, and fill Outcomes & Retrospective. Publishing/tagging releases is not part of this plan's completion criteria.

## Concrete Steps


All repository commands run from the root of this checkout, `shibuya-pgmq-adapter`. Use Mori for dependency discovery; never inspect `/nix/store` or search the filesystem root. Establish prerequisite evidence with:

```bash
mori registry search pgmq
mori registry show shinzui/pgmq-hs --full
mori registry docs shinzui/pgmq-hs
curl -fsSL https://hackage.haskell.org/package/pgmq-hasql.json
git ls-remote --tags https://github.com/shinzui/pgmq-hs.git
```

Resolve the returned local project path and inspect its package exports and sources, then verify the selected release's published Cabal file and tag contain the same API. Expected current result is latest release `0.6.1.1` without inspection. Once a suitable release exists, record its exact version here and set the actual minimum bound; no guessed future version is prescribed.

For an early proof before release, create a temporary Cabal project outside the tracked tree that lists the three local packages plus the required upstream family packages at paths discovered by Mori. Copy the existing `cabal.project` solver allowances into that temporary project and record the upstream commit. Run the same commands below with `--project-file` pointing to it. This proof may inform implementation but cannot close M1 or M4 until the released build passes. Do not overwrite a user's `cabal.project.local`.

After adding the public API/spec registration, run the focused tests with the spec's top-level description set to `Dead-letter administration`:

```bash
nix develop --no-write-lock-file -c cabal test shibuya-pgmq-adapter-test --enable-tests --test-show-details=direct --test-options='--match "Dead-letter administration"'
```

Expected output names actual executed examples for producer-to-browse, non-destructive pagination/fetch, and redrive as they are implemented, finishing with zero failures. A run selecting zero tests is not evidence. PostgreSQL executables must be available; the Nix shell supplies them. The tests install PGMQ in their ephemeral databases and need no production connection, running application, or external service started by `just process-up`.

At the final coherent boundary run:

```bash
nix develop --no-write-lock-file -c cabal build all --enable-tests
nix develop --no-write-lock-file -c cabal test shibuya-pgmq-adapter-test --enable-tests --test-show-details=direct
nix develop --no-write-lock-file -c cabal haddock shibuya-pgmq-adapter
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
git diff --check
```

Build, full tests, documentation build, changed-bundle validation, and whitespace checks must pass. Run the repository formatter on changed Haskell/Cabal files as configured in `nix/treefmt.nix`; avoid unrelated formatting churn. If `mori validate` from `just check-capabilities` has an unrelated pre-existing failure, record its exact diagnostic separately rather than silently claiming that aggregate check passed or expanding scope to registry migration.

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

The complete suite must retain existing acknowledgement, retry, FIFO, automatic dead-letter, trace propagation, and cancellation behavior. The documentation example must compile against only the public exports. Completion requires all four milestones with actual database evidence; no benchmark threshold, live feed, HTTP integration, or cross-project release is added to acceptance.

## Idempotence and Recovery


No production rows are rewritten or migrated during deployment. New envelopes gain source identity; old envelopes remain readable. Rolling back to the existing writer stops adding that field, so keep the historical mapping fallback available. Keep the redrive gate disabled during rollout until the host has supplied correct registrations and separately provisioned administrative connection capacity.

Row locks and delete/send in one transaction serialize competing redrives. Before commit, a failure restores the DLQ row; after commit, retry sees it absent and sends nothing. IDs reused by dropping and recreating a queue are outside the identity lifetime: do not replay old operator requests across queue recreation. Missing-row outcomes cannot distinguish a prior successful redrive from another actor's deletion. Hosts resolve uncertainty by browsing/fetching and checking their normal source processing records, not by resending the stored payload independently.

Tests use fresh ephemeral databases and unique fixture names, so rerunning them does not touch application queues. Do not use `just reset-database` for this work. Keep temporary dependency projects untracked and remove only the files created for this plan when switching back to released dependencies. Retain failure evidence and rerun the relevant transaction scenario after a fix before repeating the final suite.

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

Use existing Aeson, Hasql, Hasql pool/transaction, PGMQ core/hasql/effectful runtime-error mapping, text, time, and vector dependencies. Do not add `pgmq-inspect` or any web/server dependency. The upstream read requirement is `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-1`; its implementation exists locally but its released API is still the prerequisite recorded in M1. This is a standalone plan, not a child MasterPlan. The intention in frontmatter is authoritative for future implementation sessions.
