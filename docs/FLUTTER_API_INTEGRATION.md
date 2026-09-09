# Flutter Phase 1 API integration

Flutter lives in `familydocuments_flutter/` and uses Flutter 3.47.1.

| Need | Existing call | Authentication |
| --- | --- | --- |
| Sign in | `POST /auth/token?grant_type=password` (`email`, `password`) | returns bearer access/refresh tokens |
| Sign out | `POST /auth/logout` | bearer token |
| Family context | `POST /rest/rpc/household_snapshot` | bearer token |
| Search | `POST /search/ask` (`query`) | bearer token |
| OCR intake | `POST /ocr/ocr` (MIME type, base64 content) | bearer token |
| Save an explicitly filed upload | `POST /documents/save` | bearer token |
| Read and organise an upload | `POST /documents/analyse` | bearer token |

The existing browser client uses bearer authentication and `sessionStorage` for refresh tokens; the backend does not expose an HttpOnly cookie-session flow. Flutter Web therefore uses the same session-scoped refresh-token pattern. Android and iOS store that refresh token with platform secure storage. Access tokens remain in memory and are refreshed through `POST /auth/token?grant_type=refresh_token` with `{ "refresh_token": "…" }` before expiry. No credentials or tokens are logged or bundled. Flutter Web must be permitted by the existing API CORS policy. The full OCR confirmation remains the existing `create_ocr_intake_draft`, `record_ocr_intake_result`, and `confirm_ocr_intake` sequence.

## Home attachment policy

Flutter interprets only a small, deterministic set of Home commands. A clear destination such as “Save this in Rentals” saves the original file without OCR, resolving the category only within the authenticated Family. “Read”, “scan”, “OCR”, “bill”, and “invoice” explicitly request OCR. For an attachment with no clear instruction, Flutter first uses safe filename and MIME metadata: a high-confidence filename hint offers a category suggestion without OCR; an unidentifiable file is read so the user can be given an organisation result. The current OCR endpoint is synchronous, so there is no job-status or polling API to resume after refresh. Standalone text reminders are not sent because the current reminder contract requires a related document.

Run Web locally: `flutter run -d chrome`. Build: `flutter build web`. Android: `flutter run -d android`. iOS builds require macOS.
# Phase 1B Home APIs

- `POST /rest/rpc/create_reminder` creates standalone or document-linked reminders. The authenticated session determines the user and Family; clients send an explicit date/time in `Pacific/Auckland` plus an idempotency request ID.
- `POST /document-analysis/jobs` uploads a supported file and atomically persists it before queuing durable OCR/classification work. It returns HTTP 202 with job/document IDs.
- `GET /document-analysis/jobs/{id}` returns a tenant-filtered, user-safe status/result.
- `POST /document-analysis/jobs/{id}/retry` retries terminal failures.
- `POST /documents/analyse` remains unchanged for existing synchronous clients.

# Phase 2A Timeline API

`POST /rest/rpc/family_timeline` is the Timeline's unified, metadata-only data
source. A single Family-scoped RPC is used instead of separately loading
documents, reminders, saved links, imported messages and OCR jobs because those
independent lists cannot provide stable cross-type ordering or cursor
pagination. The RPC derives events from existing records; it does not create an
audit log or invent retrieval activity.

The request accepts `before_time`, `before_key`, `search_query` and
`result_limit`. Results are newest first and include a stable next cursor.
Document access and revocation, private/shared link visibility, reminder
audience and admin-only imported-message visibility are applied at the database
boundary using the authenticated user and Family membership. No client-supplied
Family identifier is accepted. List responses contain metadata only and never
include file bytes, full OCR text, message bodies, credentials or tokens.

Flutter keeps the Phase 1B OCR polling loop as the single live source for Home,
the authenticated shell indicator and Timeline. Timeline overlays those live
states on the matching server item by job ID, so queued, reading, completed and
failed states update in place without duplicate entries.

# Phase 2B Library API

`POST /rest/rpc/library_workspace` is the Library's unified metadata-only data
source. It derives the active Family from the authenticated membership and
returns authorised document summaries, real collection/category counts, tags,
trip and rental groupings, and visible saved links. It accepts optional
`search_query`, `category_filter`, `tag_filter`, `sort_order`, `result_limit`
and `result_offset` values. Search is a predictable, case-insensitive metadata
filter; file bytes, full OCR text, storage keys and internal processing details
are not returned in collection lists.

`POST /rest/rpc/update_library_document` changes a document category and its
normalised, de-duplicated tags in one guarded operation. The RPC rejects
categories outside the authenticated Family, requires edit permission and uses
`expected_updated_at` to prevent lost updates. It does not enqueue OCR.
Category creation continues to use the existing explicit `create_category`
confirmation flow. Opening locally stored source files continues to use
`document_source`; externally connected files retain the existing connected
storage behavior.

Flutter reuses the authenticated HTTP client, app-wide OCR job state and the
existing primary-destination history. Library detail history is stored only in
same-tab browser history state (not in the URL), so private record identifiers
are not exposed in URLs.
