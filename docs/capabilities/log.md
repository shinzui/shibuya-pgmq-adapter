# Capability catalog log

## 2026-10-27
* **Update**: CAP-2: record final corrected-fixture validation accurately: 196/198 numeric gates pass; both FIFO p95 bounds fail. Correctness and package validation pass; no further benchmark run or latency-fix claim.
* **Update**: Record the normal-build managed DLQ API, real two-copy topic test, and retained 197/198 performance results; keep the unresolved FIFO confidence bound and measured layout/configuration limits explicit.
* **Update**: Enable managed DLQ administration in the normal build against released PGMQ 0.7.0.0; preserve default-off redrive and distinguish correctness evidence from pending numeric performance acceptance.

## 2026-10-26
* **Update**: Document the unreleased flagged DLQ administration preview, real PostgreSQL correctness evidence, and outstanding released-dependency and performance acceptance without expanding the shipped interface.

## 2026-09-16
* **Strengthen CAP-3**: Added the `HeadPerGroup` strategy, exact dispatch tests,
PostgreSQL integration evidence for failed and delayed group heads, and a
full-drain benchmark matrix. CAP-3 now distinguishes strict grouped-head FIFO
barriers from the legacy batch-fill strategies and records the PGMQ 1.12.0
requirement.

## 2026-08-10
* **Enhance CAP-2 evidence**: Documented the 0.14 structured DLQ reason contract
and added exact unit, projection-derived property, real-PostgreSQL JSONB, and
payload serialization benchmark evidence. The capability now records the
temporary legacy dual-write, application-detail safety boundary, operator-owned
indexing, and topic fan-out cost.

## 2026-08-08
* **Adopt**: Authored the initial capability catalog for `shibuya-pgmq-adapter`
under the shared `coordination.capabilities` profile (okf-profiles v0.9.0).
Derived six capabilities (CAP-1 … CAP-6) from source, the test and benchmark
suites, the user guides, and `CHANGELOG.md`; registered the bundle in
`mori.dhall`.
* **Gaps found**: FIFO ordering (CAP-3) is proven only at query-construction and
benchmark level and its `since` is undetermined; topic-routing behavior (CAP-6)
is delegated to `pgmq-hs` with only smart-constructor and guide evidence
in-repo; the streaming adapter path (CAP-1) is exercised by the chaos suite
because `IntegrationSpec`'s `pgmqAdapter` cases are pending.
