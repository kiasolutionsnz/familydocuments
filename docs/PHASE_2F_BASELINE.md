# Reproducible Phase 2F baseline

Starting commit: `6cb952466ebaa3e95f69335dfc6b0868a6fbef5c`.

This checkout captures shared Home category choices, typed attachment replies,
pending-submission reuse, resolved clarification restoration and bounded reminder
drafts. It does not implement the Reminders destination. Telegram remains parked.

Migration `054_shared_home_clarifications.sql` follows committed migration 053.
Replay all committed migrations in filename order, including both historical 019
and 020 files. There is intentionally no 052 migration in this baseline. The new
migration includes the required shared functions but excludes Telegram delivery
lookup and callback consumption from the original uncommitted draft.

Category-option action IDs include the clarification ID, preventing collisions
when the same category is selected in a later action. Authoritative messages use
wall-clock insertion time so cancellation/restoration order is deterministic
within one transaction. The scratch gateway embeds timezone data for Auckland
reminder drafts instead of depending on absent operating-system zone files.
Browser navigation stores the application location alongside, rather than over,
Flutter's history state. This preserves the engine serial counter on startup,
refresh and navigation between Home, Library and Inbox.

Unfinished Telegram worker, linking helpers, integration UI and source-badge
changes remain only in the original working tree. Do not copy that tree or its
runtime database into this candidate.

## Disposable verification

Build the gateway from this checkout's `backend/inbound-gateway` using its pinned
Dockerfile and a unique local image tag. Run `backend/scripts/test-isolated.mjs`
with `FD_GATEWAY_IMAGE` set to that tag and these suites:

```
phase-2f-shared-clarifications.sql
phase-2f-document-review.sql
phase-2c-inbox.sql
phase-2d-conversations.sql
phase-2d-hardening.sql
```

Run Flutter formatting, analysis, all tests and `flutter build web` in this
checkout. Run Go gateway tests and the document-analysis worker/date tests.
The existing web session-store `dart:html` information item is unchanged.

From a clean committed checkout, use `node scripts/test-isolated.mjs
--manual-phase2f` in `backend`, with the explicit candidate gateway image. This
creates new uniquely labelled loopback services, synthetic accounts, two Inbox
attachments, document/category data and an OCR worker. It starts no Telegram
worker, fake Telegram server or recurring monitor. The existing local qwen3:4b
service is used without configuration changes; PostgreSQL, Auth, REST, gateway,
mail capture, PaddleOCR and application processes are separate disposable instances.

The restricted runtime manifest records the actual source commit/tree, complete
applied migration filenames and SHA-256 hashes, gateway image identity, process
IDs, fixture paths and local URLs. Credentials are stored separately, never in
source or this document. Existing manual environments are not replaced or stopped.

Verify category buttons and typed selection, same-tab clarification restoration,
save without OCR, original PDF/image opening, independent Inbox attachments and
title-first/date-first reminder drafting. Record browser results separately from
automated test results; no real Telegram or production credentials are required.
