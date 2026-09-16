# Capability catalog log

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
