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

# Phase 2C Inbox API

`POST /rest/rpc/inbox_workspace` supplies a paginated, newest-first review
queue using imported-message metadata already stored by the email pipeline. It
derives the Family from the authenticated member and supports literal sender,
subject and safe-preview search plus All, Unreviewed, With attachments, With
links and Reviewed filters. Dismissed messages leave the active queue. The RPC
does not return raw RFC822 sources, attachment bytes, headers or credentials.

`POST /rest/rpc/inbox_message_detail` returns plain, sanitised message text,
safe attachment metadata, extracted HTTPS links and completed-action summaries.
Flutter renders message text as text only; it never renders message HTML,
scripts, remote images or tracking pixels. External links use the existing
explicit safe-opening control.

Review changes use `set_inbox_review_state`. `inbox_save_attachment` saves a
clean scanned attachment into the existing document/source model and creates a
durable OCR job only when the user explicitly asks for reading. Category and
normalised tags alone never start OCR. `inbox_create_reminder` and
`inbox_save_link` wrap the existing reminder and saved-link services. All three
actions use durable request IDs recorded in `inbox_actions`, so retries cannot
duplicate their result. Authorised edits are limited to owner, Family admin,
adult member and contributor roles; viewers remain read-only. There is no
stored chat-message source in the current schema, so this phase displays real
email sources only until a chat integration persists messages in an authorised
Family-scoped source.

Migration 044 is forward-compatible: existing messages default to Unreviewed
and existing ingestion continues unchanged. Recovery is to correct and replay
the idempotent migration. Rollback requires first preserving any review state
and `inbox_actions` results that must remain auditable, then removing the Inbox
RPCs/table/indexes and the four review columns; dropping those records loses
only Inbox review/action history, not imported messages or saved documents.

# Phase 2D constrained conversation API

Flutter Home uses a bounded `ConversationController`, but it is not an action
executor. It sends user messages, staged attachments, selected suggestions and
opaque confirmation decisions to the trusted conversation gateway and renders
the authoritative response. Existing non-conversation APIs remain available to
their existing callers.

Explicit search, reminder, link, upload-destination and OCR wording is parsed
deterministically. Unresolved wording may be sent to
`POST /conversation/interpret`; its access token is fully verified before a
model call. The configured provider-neutral local model (`CONVERSATION_MODEL`,
normally `qwen3:4b`) is bounded by request size, a ten-second timeout, an
eight-call process concurrency guard and a service-only shared per-user/Family rate-limit
record. It returns a signed, short-lived proposal for one versioned allowlisted
action. Every model-derived mutation requires confirmation. Invalid, timed-out
or unavailable model output becomes a plain-language clarification.

`POST /conversation/action` submits an action to
`submit_conversation_action`; `POST /conversation/decision` accepts only an
opaque confirmation identifier and Confirm/Cancel. Migration 047 binds a
confirmation to the authenticated user, active Family, conversation, canonical
action digest, target, complete values, target timestamp, expiry and request
key. The database locks and executes the bound action once. Slow OCR is only
durably queued while the transaction is held. Server idempotency is unique by
Family, actor and request key, so a lost response or replay returns the original
execution result rather than repeating a document, OCR job, link, metadata
change, reminder or Inbox mutation.

Users with one Family are selected automatically. Users with multiple active
Families must explicitly select one; conversations and pending confirmations
are bound to it and invalidated on a Family change or revoked membership.
Search results and stored document, filename, OCR, Inbox and link metadata are
untrusted evidence and cannot authorize an action.

The initial privacy policy is enforced server-side: at most 100 conversations
per user, 60 active messages per conversation, 2,000 characters per user
message, 12 stored active references, eight references per model request and ten
pending confirmations. Inactive transcripts are archived after 90 days;
minimized security/action receipts are retained for 365 days. Authenticated
conversation deletion revokes pending confirmations and deletes transcript
state without deleting documents, reminders, links or Inbox outcomes. These
values are documented constants for a later configuration pass.

`record_conversation_job_transition` is the only conversation OCR-progress
writer. Flutter retains one shared application polling source and an in-flight
guard; unchanged job states do not append messages. Saved links accept only
public HTTPS URLs without credentials, and the destination hostname is shown
before opening or saving.
