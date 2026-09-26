# Bundle Update Log

## 2026-09-26

* **Addition**: BUG-1 reports that two active long-polling processors sharing a two-connection pool can defer `AckOk` and transactional dead-letter acknowledgement until shutdown, reproduced against adapter 0.16.0.0 on PostgreSQL 17 and 18 and the pinned remediation checkout on PostgreSQL 18. The bundle uses `coordination.bugReports` from okf-profiles v0.18.0.
