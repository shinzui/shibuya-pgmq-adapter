# Bundle Update Log

## 2026-08-10

* **Addition**: IR-1 requests end-to-end preservation of the application-defined dead-letter
  reason from `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2` in PGMQ DLQ payloads.
* **Modification**: IR-1 now targets ExecPlan 5 and fixes the compatible three-field JSON contract,
  Shibuya 0.9 dependency, null-detail semantics, and deferred legacy-field removal.
