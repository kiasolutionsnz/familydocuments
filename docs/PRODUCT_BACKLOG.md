# FamilyDocuments consolidated backlog

Recorded 2026-09-13 at the user's request. Source baseline:
70927b59bb3df79c1f95a01358ee4d52b6d93771.

These PB references are repository backlog entries, not FD ticket receipts.
In-app import is pending: the signed-in development account's My feedback list
was empty before and after attempted chat intake. Do not claim intake succeeded
or blindly resubmit without checking for duplicates first.

This is planning only. It grants no implementation, deployment, secret access,
permission changes or unattended-runner authority. Telegram remains parked.
Broad entries require clarification and scoped acceptance criteria before work.

| Reference | Item | State | Scope and next clarification |
|---|---|---|---|
| PB-01 | Mandatory Google Drive document storage | Complete — staging | Google Drive is now the only destination for newly saved originals, including conversation/OCR uploads and Inbox-approved forwarded attachments. The Inbox hand-off verifies the exact Drive upload before it creates the document record, then clears the temporary clean attachment bytes; it has no home-server fallback. Existing stored originals were deliberately not moved or deleted. Published to the private staging site for acceptance testing. |
| PB-02 | Email forwarding setup and delivery | Complete — staging | Family forwarding-address controls and trusted-sender rules are available in Settings. Forwarded attachments remain quarantined for Inbox review; on save they use the verified Drive-only hand-off from PB-01. A synthetic forwarding/Inbox contract is validated in staging; a real external email may be forwarded by the household during acceptance without changing the configured address model. |
| PB-03 | Telegram transport completion | In progress — bot replies and linking route repaired | On 2026-09-16 webhook intake completed two real private-chat messages. Windows HTTPS transport delivered the recovery reply on attempt 1 with Telegram message ID; original dead letters retained. Nine worker/transport tests pass. Staging version 20 fixes the status-only proxy allowlist with exact authenticated POST status/connect/disconnect routes; 11 proxy tests pass and unauthenticated gateway connect returns 401. Account linking, confirmed actions and attachment end-to-end acceptance remain pending. |
| PB-04 | Full Reminders destination | Complete — staging | Reconciled with PB-11: Upcoming/Overdue/Completed views, completion and schedule editing through snooze/repeat reuse the existing reminder model. Fixed standalone repeat endpoint, reload/retry errors, snooze bounds and busy menus. 14 focused Flutter tests, clean targeted analysis, release build and 11 proxy tests pass; published in private staging version 21. Email remains PB-11, mobile push PB-15, wider live acceptance PB-08. See docs/PB04_REMINDERS_ACCEPTANCE.md. |
| PB-05 | Family and account Settings parity | Complete — staging | Family Settings now provides invitations and revocation, role changes, suspension/reactivation, removal and owner transfer, all protected by explicit confirmation, TOTP identity verification and the existing server-side audit trail. Shared Library category creation remains Family-admin controlled and clearly states its Family-wide Drive effect. Account security provides authenticator setup/verification without weakening MFA; private Library storage remains explicitly deferred to PB-14. |
| PB-06 | Contextual multi-step conversation acceptance | Complete — staging verified | Focused acceptance verifies grounded invoice follow-ups never rely on model guessing; date replies retain the reminder title/time across refresh; and guided rental expenses restore the attached document, collect the required property/address/amount details, permit cancellation, reject invalid amounts without guessing, and require confirmation before any change. Ambiguous or missing references request an explicit selection, and failed operations report truthful no-change outcomes. No unrestricted action planner was introduced. |
| PB-07 | Manual feedback backlog and owner review | In progress — automation disabled | Owner decision 2026-09-17: submitted feedback waits in the backlog until the product owner reviews and decides how to handle it. No automatic coding, claiming, scheduling or deployment. Runner entrypoint now exits without reading even legacy enabled configuration. Reporter-private intake exists under PB-13; a product-owner-only cross-reporter review screen and recorded manual decisions remain to implement. Ordinary Family admins must not gain global feedback access. Automatic runner qualification is deferred. |
| PB-08 | Release acceptance and production readiness | In progress — production app deployed; acceptance deferred | 2026-09-17: At owner direction, all 29 migrations 040–069 were applied to production, preserving 41 households, 75 members, 125 Auth users, 30 documents and zero invalid constraints. The offline-scanned gateway image is live and API/Auth health pass. Public Worker version `2be67702-23b2-4081-9390-167787f6689d` serves the Flutter app at `familydocuments.app/prototype/`; root, FAQ, privacy, terms and app assets return 200, and the public JS matches the tested SHA256. The previous Worker version is retained; workers.dev/preview URLs are disabled. Authenticated public journeys, real Drive/email/Telegram and physical-phone tests remain unverified. The owner deferred additional backup/restore work and no-login reboot recovery. See docs/PB08_PRODUCTION_CUTOVER.md. Production deployed, card not fully accepted. |
| PB-09 | Rental bill-management parity | Complete — staging | Rentals remain a shared Library collection. Flutter now supports property records, confirmed bill association, bill-status changes, income recording, financial-year review, and confirmed Drive-folder placement under the shared tree contract in `docs/SHARED_LIBRARY_DRIVE_STRUCTURE.md`. The financial review is organisational only, not tax advice. Published to the private staging site for acceptance testing. |
| PB-10 | Trip-record management parity | Complete — staging | Travel remains a shared Library collection. Flutter now supports trip details, itinerary entries, travellers, costs, and explicitly confirmed document association with Drive-folder placement under the shared tree contract in `docs/SHARED_LIBRARY_DRIVE_STRUCTURE.md`. Published to the private staging site for acceptance testing. |
| PB-11 | Notification and delivery-preference parity | Complete — staging | The Reminder destination supports upcoming, overdue and completed reminders with completion, snooze, repeat and sharing controls. The agreed email-only channel has a per-member opt-out, save protection, and recent queued/sent delivery history. Published to the private staging site for acceptance testing. |
| PB-12 | Remaining legacy feature parity audit | Complete | The evidence-backed reconciliation in `docs/LEGACY_PARITY_AUDIT.md` is closed. Confirmed shared-Library work is covered by PB-09 through PB-11; remaining gaps retain their existing PB-01/PB-02/PB-05/PB-06/PB-08/PB-13 ownership. Legacy personal-link/privacy proposals are not promoted into the shared Family Library. |
| PB-13 | Feedback chat intake verification | Complete — staging | The feedback API, authenticated staging proxy and reporter-private My feedback list are connected. The missing receipt was compounded by a Home-screen defect: it cleared a typed message even when intake failed. The explicit-intent rule now accepts both “Feedback: …” and “Feedback - …”; failed feedback remains in the input with a specific retry message, while successful intake renders the created ticket receipt and clears the input. Flutter feedback tests and staging proxy tests pass. The feedback runner remains disabled under PB-07. |
| PB-14 | Optional private-to-me Library storage | Deferred | The initial Family Library is shared: active Family members can view its collections and originals according to the agreed Family access model. Revisit this only as an explicitly selected, separate private-storage capability. It would require each member's separately connected Google Drive folder, app-level exclusion from other members' Library/search results, and explicit item/collection sharing that applies both Drive and app permissions. AI may suggest organisation but may not save, move, rename, share or delete an original without confirmation. “Private” cannot exclude the owner of the Google account holding the file; client-side encryption with member-held keys would be a distinct, constrained proposal. |
| PB-15 | Mobile push reminder notifications | Deferred — mobile app release | Add opt-in push notifications for native mobile apps so due reminders can alert/vibrate on the member’s device. Require explicit iOS/Android notification permission, per-member delivery preferences, secure device-token registration and revocation, timezone-aware scheduling, delivery/retry status, and safe fallback to the existing email channel. Do not send a push for a shared reminder unless that member is an intended recipient. |
| PB-16 | Household Lists and Tasks | Complete — staging | Shared Flutter grocery/errand/chore lists, quantities/notes/sections, assignment, dates, completion/history, recurring chores, confirmed chat additions and explicit reminder-to-list copying are tested and published in private staging version 19. Staging recovered into persistent storage with restart and restored-account API checks. Telegram live transport acceptance remains in PB-03. See `docs/PB16_HOUSEHOLD_LISTS.md` for evidence and backup recovery limitations. |
| PB-17 | Home, vehicle and maintenance packs | Proposed — post-release | Add document-connected maintenance views for homes, vehicles, pets and appliances: confirmed service/expiry dates, warranties, insurance, WOF/registration, rates and compliance reminders. Each critical date or relationship must cite a saved document or require explicit member confirmation. Keep tax, legal and safety advice out of scope. |
| PB-18 | Recurring bills and subscriptions | Proposed — post-release | Provide a confirmed household view of recurring bills and subscriptions derived from saved documents or forwarded email. Show next due/renewal date, amount where confirmed, linked source, reminder state and cancellation/review notes. Revisions, receipts and duplicates must reconcile to one obligation; no payment initiation or automatic cancellation. |
| PB-19 | Monthly Family action digest | Proposed — post-release | Send an opt-in, per-member email digest summarising authorised upcoming/overdue reminders, unreviewed Inbox items and confirmed subscription/maintenance actions. Respect Family permissions, timezone and email preferences; never disclose a document title, amount or action to a member without access. Delivery must be auditable, idempotent and unsubscribable. |
| PB-20 | Private encrypted Timeline import and place reminders | Deferred — native mobile/privacy review | Allow a member to explicitly import a selected Google Maps Timeline export or equivalent location-history file, choose the date range/fields, and keep raw location history encrypted on that member’s device with a member-held key. Timeline data is private by default and must not enter the shared Family Drive tree, Family search or admin access. Support local visit-history lookup and opt-in local geofence reminders; sharing a specific visit/trip or linking it to Travel/expense records requires explicit confirmation. Include pause, retention, export and delete-all controls. Do not promise live Google Timeline syncing, background family tracking, server-readable raw GPS trails, monitoring of minors, automatic location sharing, or any data collection without mobile permission and a separate security/privacy review. |

## Evidence and reconciliation

### Confirmed storage decision

The user selected mandatory Google Drive storage after the optional-versus-default
question. Apply this to new document-saving paths before progressing to email
forwarding, full Reminders and Settings. A save is successful only after the
original is durably in the authorised Family Drive folder and its app reference
is recorded. Do not silently retain a hosted copy to work around a Drive outage.
Preserve idempotency and truthful partial outcomes if either step fails.

The previously deployed conversation attachment API staged base64 content in
the database. The isolated Drive-original candidate replaces that Home path,
but is not deployed or manually accepted. Direct upload and forwarded-email
entry points still require migration or gating. Any necessary temporary
processing retention must be explicit, bounded and distinguished from saved
originals. App metadata, permissions, conversations, reminders and search indexes
are separate from original-file storage; do not claim the application holds no
user data. Moving/deleting existing originals or changing production is not
authorised by this storage choice.

- `docs/FLUTTER_API_INTEGRATION.md`: implemented Home, durable OCR, Timeline,
  Library, Inbox and document opening; early sections are historical and must
  not override later phases.
- `docs/FEEDBACK_BACKLOG.md`: implemented private intake/runner adapter; real
  unattended execution unverified and disabled by default.
- `familydocuments_flutter/lib/features/settings/settings_page.dart`:
  Telegram disabled, additional settings deferred.
- `frontend/public/prototype/app.js`: legacy rental/travel workflows, reminders,
  Family settings and Drive connection UI. This is source evidence, not a live
  production deployment attestation.
- `docs/product/FEATURE_GAP_MATRIX.md` and `EXPERIENCE_BASELINE.md` explicitly
  contain proposals. Competitive ideas, OneDrive, emergency access, warranties,
  vehicle packs and other speculative scope are not silently promoted into
  implementation requirements.

The existing private backlog is reporter-scoped. Other reporters' tickets were
not inspected or merged. Do not claim global deduplication or copy private
feedback into this file. Established services and protected artifacts were not
modified. No runner or release was enabled by this reconciliation.
