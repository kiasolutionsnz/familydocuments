# PB-04 — Full Reminders destination

## Scope reconciled with PB-11

PB-04 covers Upcoming, Overdue and Completed views of existing reminders,
completion and schedule editing via snooze and repeat. Existing reminder creation
remains in conversation/document review. PB-11 owns email preferences and delivery
history; PB-15 owns future native push. This closeout does not introduce arbitrary
title/time editing, new delivery channels, or a second reminder data model.

## Repairs — 2026-09-17

- Repeat now calls `set_reminder_recurrence`, the existing permission-checked
  endpoint supporting standalone and document-linked reminders, rather than the
  legacy document-only `configure_reminder` endpoint.
- Snooze offers tomorrow through 365 days, matching the existing server range.
- Reload no longer returns a Future from a setState callback. Failed reloads
  remain in the recoverable error UI instead of escaping as unhandled errors.
- Completion and repeat changes await refresh; repeat/sharing menus are disabled
  while that reminder is being changed. Empty lists retain pull-to-refresh.
- Load failures explain what failed and provide Try again.

## Evidence

14 focused Flutter tests pass across reminders_page_test.dart,
reminder_service_test.dart and reminder_parser_test.dart. They cover separate
status lists, completion and refresh, failed retry then recovery, repeat edits,
snooze bounds/cancellation, 360-pixel phone layout, optional delivery failure,
the correct recurrence endpoint and reminder parsing.

Targeted Flutter analysis passes with no issues. Staging deployment evidence is
recorded in the staging STATUS.md. No schema migration, container change, email
send or user-data mutation was required. Broad live family acceptance remains
PB-08; these automated checks do not claim real email delivery.
