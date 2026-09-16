# PB-08 release acceptance — 2026-09-17

## Decision: not yet production-ready

This assessment does not approve production deployment. Staging frontend version
21 is based on Site commit 9c90aa724a08f6f62dcb72b9a62fd63be31974ba.
App HEAD is 1b472461d5fbf8a0036ab7a9f91914ebeba1c857. Telegram transport
and manual feedback-runner changes are present as uncommitted backend changes;
therefore HEAD alone is not an exact release candidate for the complete system.
The owner asked on 2026-09-17 to leave real integration and physical-phone tests
for later and complete production replacement readiness. This waives those tests
for the preparation pass only; their outcomes remain unverified. See
`PB08_PRODUCTION_CUTOVER.md` for the cutover design and verified preparation.

## Verified this review

- Full Flutter regression suite: 272 passed.
- Backend Node worker suite: 42 passed, including explicit manual feedback mode.
- Staging proxy suite: 11 passed.
- Go gateway suite: passed using the existing pinned Go 1.26.6 toolchain in a
  disposable, network-disabled container with read-only source and no credentials.
- Flutter analysis: 14 informational findings (13 missing-brace style notices,
  one deprecated dart:html import); no errors or warning-level findings, but the
  default analysis command exits nonzero. Not represented as clean analysis.
- Gateway /health: HTTP 200; staging Auth/REST/OCR and database running.
- Database healthy, named persistent volume mounted, only its private database
  network attached, and no published database port.
- Telegram scheduled worker Running. User reports Telegram looks okay; this is
  not evidence of attachment/Confirm/Cancel acceptance.
- Signed into private staging using the existing synthetic owner account.
  Library (including Rental and Travel details), Inbox, Reminders and its three
  filters, Lists, Settings and Email forwarding loaded successfully.
- At a 390 x 844 browser viewport, created `PB08 synthetic acceptance 17 Sep`,
  added one synthetic grocery item, completed it, and verified that Show completed
  reveals the checked item. These two synthetic records remain in the test Family.
  This is responsive browser evidence, not a physical-phone test.

## Drive function version drift — repaired 2026-09-17 NZ

The authenticated Google Drive screen reports that status could not be loaded.
The status RPC returns HTTP 200 with null for the unconnected synthetic Family.
Live `household_google_drive_connection_summary` matches the older migration 030
contract, not migration 058: it omits household_id and returns null rather than
the current not_connected object. The current client correctly rejects it.

Read-only inspection also confirms that authorize_google_drive_admin,
authorize_google_drive_member and select_household_google_drive_folder lack
the active_family_id scoping introduced by 058. The document authorization
function does use active_family_id and has a subsequent migration 063 definition;
blindly replaying 058 could regress it. No application migration ledger was found
(only auth.schema_migrations). Do not infer that all other migrations are absent.

After explicit owner approval, `repair-pb08-drive.mjs` reconciled exactly these
four definitions from migration 058. All other fp function definitions, ownership
and ACLs were compared unchanged, including migration 063 document authorization.
The active-Family SQL suite passed before deployment in a rolled-back transaction
and again after deployment: multiple-family selection, correct destination,
empty/authorised/active/reconnect states, MFA, viewer restrictions, suspension and
anonymous denial. Explicit anon/authenticated function ACL checks passed.
Gateway health returned 200. Browser retest now shows Not connected and Verify
identity to manage Drive, with no status-loading error. No Google connection was
made and no actual Drive file or credential was changed.

Full custom-format backup and exact four-function rollback are retained privately
under staging runtime prefix `pb08-drive-2026-09-16T21-16-35-240Z`.
Backup SHA256: `79fa7cfc76a28c0112f5bc55bab842827a0fef61101f73e7ee29a89fad872b73`.
Archive listing and byte-for-byte readback passed; this is not a full restore drill.

## Remaining gates

1. Finish authenticated integration acceptance using an approved connected test
   Family (owner MFA/Google consent if needed). Verify actual phone operation as well as responsive
   browser and widget-level phone-width coverage.
2. Real integration acceptance: save/open a Drive original; forward a synthetic
   external email into Inbox and save its attachment to Drive; receive a reminder
   email; Telegram confirmed action and supported attachment, with no duplicates.
3. Decide whether incomplete PB-07 owner-wide manual feedback review is required
   for this release or explicitly deferred. Keep automation disabled either way.
4. Freeze the complete candidate including backend worker patches; capture exact
   runtime images, migrations and non-secret configuration references.
5. Resolve temporary tunnel/address restart dependency for the intended release,
   validate backup/restore and no-login recovery for that target, and approve
   target-specific rollback. Existing staging restore evidence is historical,
   not a fresh production restore drill.
6. Owner approves the release target, audience and deployment window only after
   the preceding acceptance gates pass.

## Production preparation completed after this review

- New production backup `fd-ux-20260917-092244`: native dump SHA256
  `300BB8B248E095C39DB5E33834B1BEFB76B4AEC81A6A422F8B35E524D30B42C3`,
  encrypted Restic snapshot `7211eb0b2ec348dd717a211b8f9574e2bb3b9fd84877a959993f8bfaeeb37353`;
  integrity and isolated restore passed.
- Restored both Auth and application schema in a disposable isolated database.
  All 29 migration files 040–069 applied; 41 households, 75 memberships,
  125 Auth users and 30 documents remained, with zero invalid constraints.
- Built the Phase 2F gateway candidate without network access. Offline Trivy
  scan found zero High/Critical vulnerabilities. Built a Flutter candidate for
  the existing production API and `/prototype/` path with the public Drive
  client ID. Neither artifact was published.
- Unattended worker recovery, production Worker route/package preservation,
  exact candidate freeze and fresh cutover-time backup remain open. A completed
  migration rehearsal is evidence of compatibility, not a deployment approval.

## Rollback boundary

Staging frontend version 20 is the prior UI rollback; it does not roll back the
database, workers or gateway. The approved staging repair changed four functions;
its exact rollback SQL is retained beside the backup above. No service was
restarted or production changed. A production rollback must name the production artifacts and verified
backup; do not substitute staging container names or a stale backup.
