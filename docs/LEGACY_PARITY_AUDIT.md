# Shared Library parity audit

Recorded 2026-09-15. This audit compares the legacy prototype routes with the
Flutter application and records only evidenced scope. It follows the confirmed
product direction: originals belong in the selected shared Family Drive folder,
and Rentals, Travel, Medical and later member-created categories are Library
collections, not separate top-level products.

| Legacy area | Shared-Library treatment | Current evidence | Audit disposition |
|---|---|---|---|
| Rentals | `Library > Rentals`, grouped by property and financial year | Flutter property, bill-status, income and year-end controls; confirmed Drive placement | Complete in PB-09; staging acceptance remains part of PB-08 |
| Travel | `Library > Travel`, grouped by trip | `travel_workspace`, trip/record RPCs, Flutter trip controls for itinerary/travellers/costs, and confirmed Drive placement | Published to private staging for acceptance testing |
| Reminders/notifications | A destination beside Library, not a collection | Reminder dashboard/actions, due-day email queue, personal email preference, and queued/sent delivery history | Complete in PB-11; staging acceptance remains part of PB-08; email remains the only delivery channel |
| Family/settings | Shared Family administration | Flutter Settings exposes Google Drive, Family/categories, and email-forwarding controls | Remaining account-recovery/security parity stays in PB-05; do not weaken MFA or Family roles |
| Documents/lifecycle | Shared Library documents | Flutter Library provides document details, metadata editing and source opening; active records are permission-filtered | Any archive/delete/recovery work must be reconciled against the current backend contract under PB-01/PB-08, not inferred from prototype controls |
| Saved links | Separate personal-link capability, not a document collection | Existing link model is private-by-default and separately permission-filtered | Retain as a separate capability. It does not alter the agreed shared access model for Family document collections |

## PB-12 closure

The prototype was used only as implementation evidence. Its route names, local
storage choices and proposed privacy features are not product authority. The
following reconciliation is complete:

- Rentals, Travel and Reminders are accounted for by PB-09, PB-10 and PB-11,
  respectively, and are published to private staging.
- Original-file storage, forwarded-email ingestion, family/account settings,
  contextual conversation, release acceptance and feedback intake remain in
  their existing PB-01, PB-02, PB-05, PB-06, PB-08 and PB-13 cards. PB-12 does
  not duplicate or broaden them.
- Telegram remains parked in PB-03. Private-to-me Drive storage remains
  explicitly deferred in PB-14. Neither is a consequence of creating a shared
  Library collection.
- Saved Links are not Drive originals and therefore remain a separate,
  personal-link capability. They must not be presented as a private exception
  to the shared Family Library decision.

No additional PB-12 child card is required. Staging acceptance and any future
production release remain separate from this audit.

## Guardrails

- A new Library collection may be created by an active Family member, but it is
  visible to the Family under the agreed shared access model.
- AI may propose a category, collection, Drive folder or relationship. A member
  must confirm before the app creates/moves/saves an original or changes sharing.
- The app must use only the selected FamilyDocuments Google Drive folder and
  retain the Drive file reference rather than duplicate the original.
- Private-to-me storage remains deferred in PB-14 and must not be inferred from
  collection creation.
