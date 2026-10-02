---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [Exhausted acknowledgement skips the failure hook](exhausted-acknowledgement-skips-failure-hook.md) - Adapter 0.16.0.0 propagates a permanent acknowledgement failure to the application but does not invoke PgmqAdapterEnv.onAckFailure for that delivery.
- [Long polls can starve acknowledgements on a shared pool](long-polls-starve-acknowledgements-on-a-shared-pool.md) - Two long-polling processors sharing a two-connection pool run their handlers but defer AckOk and transactional dead-letter acknowledgement until shutdown.
- [Retried dead-letter move can duplicate a copy](retried-dead-letter-move-can-duplicate-a-copy.md) - Adapter 0.16.0.0 sends a DLQ copy before deleting the source row in one transaction, so retrying after an ambiguous successful commit can send a second copy even though the source is already absent.
- [A server-side long poll outlives its killed client and consumes a read attempt](long-poll-outlives-a-killed-client-and-consumes-a-read-attempt.md) - LongPolling issues pgmq.read_with_poll, which keeps looping on the PostgreSQL server after the worker process dies and charges the next visible message a read attempt that no handler ever sees.
