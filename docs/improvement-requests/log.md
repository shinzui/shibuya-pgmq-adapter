# Bundle Update Log

## 2026-10-27
* **Update**: IR-3: preserve actual release-validation evidence: completed implementation, 203 passing examples, and two failed FIFO confidence bounds in the corrected experiment. No full acceptance or publication claimed.
* **Update**: Record completed browse/fetch/default-off redrive implementation and compiled embedding evidence; retain proposed status because plan 9 has one unresolved performance gate and no published release.

## 2026-08-19
* **Addition**: Expose dead-letter-queue browse and redrive for adapter-managed DLQs (IR-3) filed from keiro-ui
* **Addition**: Surface queue depth and age context for processors consuming pgmq queues (IR-2) filed from keiro-ui

## 2026-08-10
* **Addition**: IR-1 requests end-to-end preservation of the application-defined dead-letter
reason from `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2` in PGMQ DLQ payloads.
* **Modification**: IR-1 now targets ExecPlan 5 and fixes the compatible three-field JSON contract,
Shibuya 0.9 dependency, null-detail semantics, and deferred legacy-field removal.
* **Completion**: IR-1 shipped in `shibuya-pgmq-adapter` 0.14.0.0 on Hackage and under annotated
tag `v0.14.0.0`, backed by exact unit/property tests, a real PostgreSQL JSONB assertion, the
complete 161-example database suite, payload benchmarks, and reader migration guidance.
