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
