# Bundle Update Log

## 2026-09-26

* **Modification**: BUG-1 now also reproduces on Hackage adapter 0.16.1.0 with Shibuya core 0.10.0.0 on PostgreSQL 17 and 18. The isolated live package probe records the same 25-second stall and post-shutdown completion; `affectedVersion` names the latest observed release.
* **Addition**: BUG-1 reports that two active long-polling processors sharing a two-connection pool can defer `AckOk` and transactional dead-letter acknowledgement until shutdown, reproduced against adapter 0.16.0.0 on PostgreSQL 17 and 18 and the pinned remediation checkout on PostgreSQL 18. The bundle uses `coordination.bugReports` from okf-profiles v0.18.0.
