# Bundle Update Log

## 2026-09-30
* **Update**: BUG-1 records its root cause: read_with_poll pins one pool connection per processor while Shibuya's ingester polls concurrently with the handler, and hasql-pool's unordered waiters let re-polls starve acknowledgements; the same client-side LongPolling remedy fixes it.
* **Addition**: BUG-4 reports that a server-side long poll outlives its killed client and consumes a read attempt, traced from keiro's crash-redelivery runs and PostgreSQL backend logs; the recommended remedy is a client-side LongPolling loop that never issues read\_with\_poll.

## 2026-09-28
* **Report**: BUG-2 records the 0.16.0.0 exhausted-acknowledgement failure-hook gap and its 0.16.1.0 fix, with sealed PostgreSQL 17 and 18 reproductions and passing current-release controls.
* **Report**: BUG-3 records duplicate direct-DLQ copies after a retried move on 0.16.0.0 and the 0.16.1.0 delete-first repair, with fault-injected external results.

## 2026-09-26
* **Modification**: BUG-1 now also reproduces on Hackage adapter 0.16.1.0 with Shibuya core 0.10.0.0 on PostgreSQL 17 and 18. The isolated live package probe records the same 25-second stall and post-shutdown completion; `affectedVersion` names the latest observed release.
* **Addition**: BUG-1 reports that two active long-polling processors sharing a two-connection pool can defer `AckOk` and transactional dead-letter acknowledgement until shutdown, reproduced against adapter 0.16.0.0 on PostgreSQL 17 and 18 and the pinned remediation checkout on PostgreSQL 18. The bundle uses `coordination.bugReports` from okf-profiles v0.18.0.
