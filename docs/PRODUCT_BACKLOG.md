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
| PB-01 | Mandatory Google Drive document storage | In progress; not deployed | Google Drive is the only destination for saved original documents, including OCR uploads and forwarded attachments. No home-server or provider-hosted original-file option and no silent fallback. Reuse authorised connect/folder/reconnect/disconnect, enforce active-Family access, and block saving with actionable connection guidance when Drive is unavailable. Existing stored originals must not be moved or deleted without a separately approved migration. |
| PB-02 | Email forwarding setup and delivery | Needs clarification | Expose the existing Family forwarding-address/setup and sender controls; verify real email, independent attachments, Inbox review and saving. Confirm desired address naming and permitted senders. |
| PB-03 | Telegram transport completion | Parked | Resume only on explicit approval. Finish private-user linking, follow-ups, attachments and end-to-end acceptance through the shared orchestrator. No family-group scope or real Telegram calls authorised here. |
| PB-04 | Full Reminders destination | Needs clarification | Upcoming, overdue and completed lists with editing/completion, reusing existing reminders. Chat reminder creation is already implemented. Confirm notification channels and delivery preferences separately. |
| PB-05 | Family and account Settings parity | Needs clarification | Bring across applicable member/invitation, sharing, category, account-recovery and security controls without weakening existing step-up permissions. Establish a feature-by-feature legacy parity checklist first. |
| PB-06 | Contextual multi-step conversation acceptance | Needs clarification | Validate recent invoice questions, date replies and guided rental expenses; identify remaining missing-entity/follow-up cases. Require explicit confirmations and truthful partial outcomes, not an unrestricted action planner. |
| PB-07 | Feedback runner qualification | Blocked on configuration and approval | Qualify isolated execution image, credentials, restricted network, bounded claims/recovery and real invocation. Keep the 30-minute runner disabled and production deployment separate. |
| PB-08 | Release acceptance and production readiness | Needs clarification | Complete phone/browser regressions and real integration acceptance for the exact candidate commit; separately approve deployment and rollback. Tests/commits alone never mean Released. |
| PB-09 | Rental bill-management parity | Needs clarification | Legacy UI includes properties, tracked bills and confirmed document associations. Compare Flutter Library and guided expense flow with those existing workflows; migrate only missing agreed controls, not a new property-management product. |
| PB-10 | Trip-record management parity | Needs clarification | Legacy UI includes creating trips and confirming flights/accommodation/booking records. Flutter already groups documents by trip. Identify missing creation/edit/association controls; no booking or itinerary-planning expansion. |
| PB-11 | Notification and delivery-preference parity | Needs clarification | Review existing reminder notifications and notification history; identify Flutter preference and unread-state gaps. Confirm channels before implementing new delivery behaviour. |
| PB-12 | Remaining legacy feature parity audit | Needs clarification | Compare legacy auth/onboarding, document sharing/lifecycle, saved-link management and category/entity controls against current Flutter. Record only evidenced missing behaviour as child tickets; do not assume every old proposal was shipped. |
| PB-13 | Feedback chat intake verification | Needs investigation | On the current dev account, explicit Feedback text was entered and Send selected but no receipt appeared and My feedback remained empty. Distinguish browser-input automation failure from an app defect before fixing; ensure failed intake retains text and shows an actionable error if reproducible. |

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
