---
type: Bug Report
title: Exhausted acknowledgement skips the failure hook
description: >-
  Adapter 0.16.0.0 propagates a permanent acknowledgement failure to the
  application but does not invoke PgmqAdapterEnv.onAckFailure for that delivery.
generated:
  by: openai/codex
  at: "2026-09-28T00:06:38Z"
bugId: BUG-2
status: fixed
severity: degraded
fixedVersion: "0.16.1.0"
resolution: >-
  The acknowledgement handle now invokes onAckFailure when transient retries
  are exhausted and throws PgmqAcknowledgementException synchronously. The
  0.16.1.0 release also propagates automatic dead-letter failure after calling
  the hook. The released current adapter passed the same PostgreSQL 17 and 18
  postmaster-restart scenario that reproduced this gap on 0.16.0.0.
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter
capability: mori://shinzui/shibuya-pgmq-adapter/okf/capabilities/concepts/CAP-1
affectedVersion: "0.16.0.0"
environment: >-
  Adapter 0.16.0.0 with Shibuya core 0.9.0.3 on durable PostgreSQL 17 and 18.
  A postmaster restart occurs while a handler's acknowledgement is held at a
  gate; acknowledgement retry is allowed to exhaust after the restart.
observed: >-
  The application exposed an acknowledgement exception through waitApp and
  recovered through the restart loop, but onAckFailure was not called. Both
  historical PostgreSQL majors reproduced the exact
  acknowledgement: ack-failure-hook-not-fired label while conserving and
  draining every producer ID.
expected: >-
  An exhausted acknowledgement error invokes the configured onAckFailure hook
  once for the affected message and remains observable as a failed application
  lifecycle, so operators can distinguish it from a successful acknowledgement.
reproduction:
  - Start pgmqAdapter with an onAckFailure counter and a restart loop on a durable PostgreSQL 17 or 18 server.
  - Hold one handler after its durable effect and before it returns AckOk; stop and restart the postmaster while a separate producer continues sending.
  - Release the handler, allow acknowledgement retries to exhaust, and inspect waitApp and the hook counter.
  - On 0.16.0.0, waitApp reports the error but the counter stays zero; repeat on 0.16.1.0 and observe the counter increment.
workaround: >-
  Upgrade to adapter 0.16.1.0 or later. On 0.16.0.0, monitor the application
  lifecycle exception directly rather than relying on the absent callback.
---

# Exhausted acknowledgement skips the failure hook

The verification scenario `shibuya/pgmq-adapter/concurrency/postgres-outage-and-the-restart-loop`
in `mori://shinzui/keiro-runtime-kenshou` reproduces the defect on historical
PostgreSQL 18 and 17. Its sealed results are in that project's
`runs/01a0de11-51ed-7150-9859-082ef2770680/run-result.json` and
`runs/01a0de13-05b9-73db-8105-0cdecfa2b820/run-result.json`
(artifact-level URIs pending). The polling arm processed 100 IDs and the
acknowledgement arm processed 101 IDs, with only the gated in-flight message
duplicated; both source queues drained. The missing hook is therefore distinct
from message loss and from the already-observed application exception.

The isolated published 0.16.1.0 package passed the corresponding PostgreSQL
18 and 17 sealed runs at `runs/01a0de0e-274c-76f0-b197-fb148c673ef4/run-result.json`
and `runs/01a0de0e-c680-76ca-a57b-8acd846289bf/run-result.json` in
`mori://shinzui/keiro-runtime-kenshou` (artifact-level URIs pending). Its
changelog and acknowledgement-handle source identify the hook and exception
repair. The historical 0.16.0.0 handle lacks the hook on its decision path.
