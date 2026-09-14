# Required Drive storage implementation

Sequence: Google Drive, email forwarding, full Reminders, then Settings.
Use the isolated phase2f-reproducible checkout. Preserve the separate original
mixed checkout, Telegram work, existing manual environment and production data.

## First increment (not deployed)

- Migration 058 replaces first-membership selection in the Drive authorization,
  status and folder-selection functions with existing active-Family resolution.
- Existing MFA and role checks remain. No-connection status is explicit, not a
  null result. No bytes or credentials are moved by this migration.
- Flutter DriveService reads the existing RPC using current authentication,
  validates the response and does not cache user/Family connection state.
- All 238 Flutter tests passed, including thirteen new fake HTTP/model tests.
  Formatter completed successfully (subsequent check: zero changed files).
  Analysis returned only the pre-existing session_store_web.dart:2 dart:html
  information item (exit 1, no errors or warnings).
- Flutter Web production build completed successfully (exit 0, 68.9 seconds).
- Full migration replay through 058, drive-active-family.sql and
  google-drive-exact-files.sql passed with exit 0 in disposable runtime
  fd-test-4ef7a521686f. Its labelled resources were removed by the test runner.

## Drive setup UI increment (2026-09-14, not deployed)

- Settings now opens the Drive status/setup screen. It supports real gateway
  connect, folder listing/creation/selection and confirmed disconnect operations.
- Existing Auth TOTP enrollment/challenge/verification provides the required
  administrator identity step-up. Only the updated refresh token is persisted.
- Web uses Google's existing popup authorization-code model and drive.file scope.
  The public GOOGLE_DRIVE_CLIENT_ID must be supplied at build time. The OAuth
  secret and token-encryption key remain gateway-only. Native setup currently
  directs the user to the web app; no native OAuth package was added.
- Drive requests carry the displayed Family as an expectation, not authority.
  The gateway compares it to authenticated RPC resolution and rechecks access
  after the code exchange. Strict JSON rejects unknown/trailing request content.
- All 249 Flutter tests passed (exit 0); gateway go test ./... passed (exit 0)
  in a network-disabled disposable container. Formatter check had no changes.
  Analysis has zero errors/warnings and only the existing dart:html info.
- Dev-targeted Flutter Web build completed with exit 0 in 64.8 seconds, using
  APP_VERSION=70927b5-drive-setup-dev and the staging /_api URL. This is a local
  uncommitted-source build, not a published release.
- Real disposable Auth enrollment, verification, AAL2 issuance and global
  logout passed with synthetic credentials (totp-mfa-e2e.mjs, exit 0). Runtime
  fd-test-43d6c24c3100 replayed all migrations and cleaned up its own resources.
- The existing dev gateway's GOOGLE_DRIVE_CLIENT_ID, GOOGLE_DRIVE_CLIENT_SECRET
  and GOOGLE_DRIVE_TOKEN_KEY were checked for presence only: all absent. No
  Google credential was read, no real Google authorization attempted, and no
  existing service was changed.
- This is setup infrastructure, NOT acceptance of mandatory Drive storage.
  Conversation saves/OCR still use their pre-existing source paths. Do not
  advertise or deploy this as the completed Drive-only release.

## Remaining Drive work before acceptance

1. Extend disposable integration coverage to Family switching during every
   setup mutation, including race/revocation immediately before persistence.
2. Configure a separate dev Google OAuth client and obtain user authorization
   for the final real-account browser test. Never reuse production credentials
   implicitly. Verify popup/CSP behavior in the deployed staging wrapper.
3. Replace persisted conversation attachment bytes with durable Drive references.
   Introduce resumable/idempotent upload/finalization and accurate partial outcomes.
   Do not perform Drive network calls inside database transactions.
4. Route new original-file saves through that path. Remove local fallback across
   direct uploads, conversation saves and original document retrieval.
5. Make the shared OCR worker read authorized Drive originals, without retaining
   another permanent byte copy. Audit temporary OCR files and cleanup/recovery.
6. Verify setup in a real browser, including authenticator enrollment recovery,
   popup cancellation/blocking, quota and unavailable Google services.
7. Validate Drive quota, disconnect, permission revocation, duplicate/retry,
   refresh, and upload-succeeded/database-failed recovery with fake Google and
   disposable services; then separately verify real OAuth with the user.

Only after Drive acceptance proceed to email intake: forwarded originals must
also go to Drive, including safe pre-save processing and unavailable-Drive
handling. Existing locally stored originals are not migrated or deleted here.

## Release gate

### Dev build, 2026-09-14

Rebuilt with explicit FAMILYDOCUMENTS_API_BASE_URL:
`https://familydocuments-phase2f-staging.inderchauhan.chatgpt.site/_api`
and APP_VERSION `70927b5-drive-foundation-dev` (an uncommitted increment on
baseline 70927b5, not a new committed release).
Build completed with exit 0 in 67.9 seconds. The generated main.dart.js contains
the dev API and does not contain the default production-like API URL.
SHA256: `5DF99AA92832BBF61A7FB478EE53E99B58D3ECEA4D20381EFACD88109F5188A3`.
This replaces the earlier generic local build output only. It has not been
published; migration replay/security validation still gates deployment.

No original-file storage-policy change is active yet. This first increment is
not a complete Drive integration and must not be advertised as one. No external
Google authorization, deployment, existing database migration, stored-file
deletion or production change has been performed.

## Isolated Drive-original candidate (2026-09-14, not deployed)

- Migrations 058 and 059 now provide explicit active-Family checks, a durable
  metadata-only Drive upload reservation, and Drive-backed conversation
  attachments. The gateway sends a new PDF/JPEG/PNG original to the connected
  Family Drive folder first, verifies its Google ID, parent, metadata and MD5,
  then records a reference. The reservation's unique digest and pre-generated
  Google ID make a retry converge on the same original.
- New Home document saves and OCR requests use the Drive reference. OCR claims
  do not carry Drive document bytes; the worker fetches them via a leased,
  authorised gateway call. Existing historical originals stay accessible.
  No existing document, user connection or credential was copied or migrated.
- The Flutter Settings connection flow uses the same existing Google OAuth
  client and `drive.file` popup code flow as the static app. Its public client ID
  was supplied to an isolated web build, not committed into source. The gateway
  still requires the matching server-side OAuth client secret plus a new,
  separate dev encryption key. The connected Google account itself must
  authorise the dev Family; no production user connection is reused.
- Disposable PostgreSQL replay and Drive/clarification security tests passed.
  Gateway Go tests, all 249 Flutter tests and the dev-targeted Web build passed.
  Flutter analysis reports only the existing Web `dart:html` deprecation info.
- The current Google Cloud browser account exposes no projects, so the approved
  staging JavaScript origin could not be inspected or added for this client.
  The existing dev gateway lacks Google OAuth settings. Accordingly this build
  has not been published or manually accepted, and Drive-only saving is not yet
  available in the current staging deployment.

Before dev release, an operator with access to the existing OAuth client's
Google Cloud project must verify/add the exact staging origin, then place the
existing client ID/secret and a distinct dev token key in a restricted dev
gateway configuration. Use only synthetic dev accounts and a newly authorised
dev Family Drive folder. Rebuild the gateway and run the real browser sequence:
connect, select folder, save, reopen, OCR, retry, revoke, and disconnect. Do not
deploy the new Home upload path with an unconfigured gateway.

Existing direct upload and email-ingestion entry points are retained for their
current callers. They are not an alternative storage choice in the Flutter UI,
but they must be migrated or gated before claiming that *all* new originals,
including forwarded email attachments, are Drive-only. Email forwarding remains
the next phase, not part of this candidate.
