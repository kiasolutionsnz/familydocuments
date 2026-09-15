# Shared Family Library Drive structure

## Decision

FamilyDocuments has one shared Family Library. The selected Family Google Drive
folder is the source of truth for original files; the application holds the
metadata, relationships, permissions, search index and exact Drive references.
Rentals, Travel, Medical and member-created categories are Library collections,
not separate products or top-level application destinations.

The application creates and maintains folders only after a member explicitly
confirms the proposed categorisation/association. AI can make the proposal; it
cannot create, move, rename, share or delete a Drive original on its own.

## Human-readable tree

The selected folder is the only Drive location the application may organise.
The application creates the following children lazily, only when needed:

```text
<selected FamilyDocuments folder>/
  Library/
    <Collection>/
      <item-specific folders when applicable>/
  _Unfiled/
```

Examples:

```text
FamilyDocuments/
  Library/
    Rentals/
      12 Example Street/
        FY 2025–26/
          Income/
          Expenses/
            Rates/
            Insurance/
            Repairs & maintenance/
            Compliance/
          Year-end statements/
    Travel/
      2026 — Fiji/
        Flights/
        Accommodation/
        Itinerary/
    Medical/
      Jane/
        2026/
      Sam/
        2026/
  _Unfiled/
```

`_Unfiled` is for a confirmed original with no confirmed collection or
association. It is not a processing/quarantine area: failed and unconfirmed
uploads must not be represented as saved originals in Drive.

## Time periods and year-end records

Rental records use a financial-year folder below each property. The default
New Zealand label is `FY 2025–26` for the period 1 April 2025 to 31 March 2026;
the household's configured balance date must be used when the household has an
approved different period. Inland Revenue describes the usual NZ tax/income
year as 1 April to 31 March. [IRD glossary](https://www.ird.govt.nz/glossary-source)

The app assigns an expense or income record to a financial year from its
confirmed transaction/due date, not its upload date. It can generate a year-end
document pack and totals summary for review, but it must label that output as an
organisational summary—not tax, accounting or profit advice—and retain links to
the originals. Income is a distinct record type from expenses; the app must not
infer it from a bill.

Medical and other time-based collections use calendar-year folders below the
person or collection when a confirmed date exists. Trip folders use the trip
start year in a stable label such as `2026 — Fiji`; use `Undated — Fiji` until a
date is confirmed rather than guessing a year.

## Folder naming and identity

- Folder labels are readable and derived from the confirmed collection, rental
  address/name or trip name. The app removes path separators/control characters
  and applies a stable collision suffix only when required.
- The database records the Google Drive folder ID, parent ID, node type and
  related Library entity/category. IDs, not names, are authoritative.
- Folder creation is idempotent and serialised per Family/node. Retry finds the
  recorded node or the exact app-created Drive ID; it never guesses from a
  similarly named user folder.
- Renaming a collection/property/trip does not rename an existing Drive folder
  automatically. The app offers an explicit, confirmed rename with a truthful
  partial-failure result.

## Confirmed-save flow

1. A member selects or confirms the category and, where relevant, the rental
   property or trip.
2. The app shows the exact proposed Drive destination.
3. On confirmation, the backend reserves the Library node and creates the
   missing app-owned ancestors under the selected Family root.
4. The original is uploaded directly to that final folder (or an already saved
   Drive original is moved only after an explicit move confirmation).
5. The backend records the Drive ID/parent reference and Library relationship.
   A result is successful only when both are durable; otherwise it reports the
   actual partial state and offers safe retry.

Existing originals are never bulk-moved. A user may organise one existing item
at a time after seeing its source and destination.

## Access and manual Drive use

All initial Library collections are shared through the Family application.
Whether each member can also browse the root directly in Google Drive is an
independent Google Drive sharing choice. The connected Google-account owner
retains ultimate Drive control. If direct Drive browsing is enabled, grant
members only the agreed Drive role on the selected root; do not use a broader
Drive grant or share a member's entire Drive.

The app uses its existing selected-folder boundary. It must not scan, reorganise
or infer structure outside that root. Manual moves/renames/deletions are
detected as source-unavailable or out-of-sync; the app offers repair guidance,
not a silent replacement.

## Delivery sequence

1. Add a database-backed Drive-node registry and a safe gateway operation that
   can create a child only under an authorised app-owned parent.
2. Add confirmed destination previews and lazy tree creation for collections,
   rentals and trips.
3. Route new confirmed uploads directly to their final folder; add explicit
   per-document organisation for existing originals.
4. Add reconciliation/repair states and automated tests for retries, name
   collisions, cross-Family attempts and Drive failures.
5. Only then publish a staging candidate and test with synthetic Drive data.
