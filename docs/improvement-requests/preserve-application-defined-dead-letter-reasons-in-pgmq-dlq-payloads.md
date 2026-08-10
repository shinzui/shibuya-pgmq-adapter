---
type: Improvement Request
title: Preserve application-defined dead-letter reasons in PGMQ DLQ payloads
description: >-
  Adopt Shibuya's application-defined permanent-processing reason without duplicating its closed
  constructor vocabulary, and preserve the stable reason code and detail in PGMQ DLQ payloads.
timestamp: 2026-08-10T20:57:14Z
requestId: IR-1
status: proposed
origin: mori://shinzui/shibuya/packages/shibuya-core
targetPlan: mori://shinzui/shibuya-pgmq-adapter/plans/5-preserve-structured-dead-letter-reasons-in-pgmq-dlq-payloads
---

# Improvement Request: Preserve Application-Defined Dead-Letter Reasons in PGMQ DLQ Payloads

## Status

Proposed.  This is the adapter rollout required after
`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2` and before
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-9` can claim end-to-end PGMQ
dead-letter support for declarative router selection.

## Context

`Shibuya.Adapter.Pgmq.Convert.mkDlqPayload` currently owns an exhaustive `reasonToText` match over
`PoisonPill`, `InvalidPayload`, and `MaxRetriesExceeded`.  Its property-test generator and shrinker
repeat the same closed vocabulary, and the user documentation lists only those textual encodings.

The public reason requested by
`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2` adds an application-defined
permanent-processing outcome with a stable code and explanatory detail.  Merely adding a catch-all
`show` case in this adapter would weaken the DLQ contract and could lose the machine-readable code.
Keeping another exhaustive renderer here would continue coupling the adapter to every core reason
constructor.

## Requested Change

Adopt `shibuya-core ^>=0.9.0.0` and its total public dead-letter reason projections.  Remove the
adapter's duplicate constructor interpretation.  Every newly written PGMQ DLQ body must contain
the canonical compatibility rendering in `dead_letter_reason`, the stable code in
`dead_letter_reason_code`, and the verbatim optional detail in `dead_letter_reason_detail`.  The
detail key is always present: no-detail reasons use JSON `null`, while an empty detail remains an
empty JSON string.

This dual-write policy is the compatible migration window.  Existing consumers may continue to
read `dead_letter_reason`, while new consumers should prefer the structured fields and fall back
to the legacy field for old rows.  Removal of `dead_letter_reason` is deferred to
[Plan 6](../plans/6-remove-the-legacy-dead-letter-reason-field-after-structured-rollout.md) and is
not authorized by this request.

Update generators, shrinkers, unit/property tests, database-backed DLQ tests, capability evidence,
and user documentation.  The adapter must remain responsible for reliable transport and PGMQ
transactionality, while `mori://shinzui/shibuya/packages/shibuya-core` remains responsible for the
reason vocabulary and canonical semantic encoding.

## Acceptance

1. The workspace resolves `shibuya-core ^>=0.9.0.0`, and `mkDlqPayload` accepts its released
   application-defined reason without a partial production match, catch-all `show`, or
   adapter-owned copy of Shibuya's constructor vocabulary.
2. A reason with code `keiro.router.selection.recipient_overflow` and safe explanatory detail
   reaches a real PGMQ DLQ with exact, separately queryable `dead_letter_reason`,
   `dead_letter_reason_code`, and `dead_letter_reason_detail` values.
3. Existing poison, invalid-payload, and retry-exhaustion compatibility renderings remain in
   `dead_letter_reason`; their structured codes are stable, their carried details are preserved,
   and retry exhaustion writes an always-present JSON-null `dead_letter_reason_detail`.
4. Property generators and shrinkers cover the new reason and remain total when Shibuya's public
   reason API evolves according to its documented compatibility contract.
5. DLQ send/delete atomicity, acknowledgement idempotence, trace propagation, and retry behavior
   remain unchanged in database-backed tests.
6. The adapter's public guide documents all three fields, null and empty-string semantics, and
   the temporary dual-write migration to the separately gated breaking work in Plan 6; capability
   evidence points to executable proof.
7. The change ships in a tagged `shibuya-pgmq-adapter` release compatible with the tagged
   `shibuya-core` release that fulfils
   `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-2`.

## Requested Deliverables

- Canonical reason encoding integration in the PGMQ adapter.
- Unit, property, and database-backed DLQ coverage.
- Updated capability evidence, JSON contract documentation, and migration notes.
- Tagged release.
