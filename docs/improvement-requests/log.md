# Bundle Update Log

## 2026-08-10

* **Addition**: IR-1 requests end-to-end preservation of the application-defined dead-letter
  reason from `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2` in PGMQ DLQ payloads.
* **Modification**: IR-1 now targets ExecPlan 5 and fixes the compatible three-field JSON contract,
  Shibuya 0.9 dependency, null-detail semantics, and deferred legacy-field removal.
* **Completion**: IR-1 shipped in `shibuya-pgmq-adapter` 0.14.0.0 on Hackage and under annotated
  tag `v0.14.0.0`, backed by exact unit/property tests, a real PostgreSQL JSONB assertion, the
  complete 161-example database suite, payload benchmarks, and reader migration guidance.
