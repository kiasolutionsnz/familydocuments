# Production app URL and brand alignment — 2026-09-18

The public website remains at `https://familydocuments.app/`. The Flutter product is now at `https://familydocuments.app/app/`; public sign-in and registration links point there. The old `/prototype/` entry point forwards to `/app/` for existing bookmarks. The app uses the website's violet, ink, warm-paper, and mint palette in its login and main shell, with matching accents in chat, Library, and Timeline.

Scope: frontend Worker only. The production API, Auth configuration, database, and containers were not changed. The Flutter build used `/app/` as its base path and the existing local public Drive OAuth client configuration. The deployed bundle SHA-256 is `80FFD3E5C9094DF2F9B3DB313DA07AE623CE7AC3E26BD62CE99FA0037F37C8D3` and Worker version is `a8684c9a-bb53-4af9-a51f-362d883042d9`. Previous Worker versions `9659ba90-92e9-474c-9563-593dc05b1e2c` and `dc4c2610-f094-4011-af15-a5e2a955df59` remain the rollback references.

Verification: Flutter analysis had no errors or warnings (16 pre-existing info lints); the full 273-test suite passed before the final three accent-only edits, and targeted Auth/conversation tests passed afterward. Production web build and Worker packaging passed. The public `/`, `/app/`, `/faq`, `/privacy`, `/terms`, and API health routes returned HTTP 200; the live `/app/main.dart.js` hash matched the build. The `/prototype/` static page serves a redirect to `/app/`. Authenticated visual review and real signup/password-manager acceptance remain user-facing checks.

## Profile and login update — 2026-09-18

The production `/app/` login has a refreshed design and links to Terms and Privacy. Profile now displays account/family details, lets the user change their display name, and accepts/removes a private JPEG, PNG, or WebP photo up to 1 MiB. The new `070_member_profile.sql` migration was applied after a verified production `pg_dump` snapshot (`backend/backups/profile-20260918-110702/database.dump`); only the signed-in user can execute the profile RPCs and anonymous access was denied in staging tests. The updated name is reflected across that user's family memberships; the photo remains private to the account.

The complete 275-test Flutter suite passed. The live app bundle SHA-256 is `F541223F3CD22FFC72124C47307E4925306D5160CC911CC61ABF2850D895C3AA`; Worker version `db98967e-c3dc-4d56-a741-8bd767cb7e76`. The public `/`, `/app/`, `/terms`, `/privacy`, and API health routes returned HTTP 200 after deployment, and the live bundle hash matched the tested build. A signed-in, real-photo acceptance check remains for the owner.

## Larger photo attachments — 2026-09-18

The `/app/` picker accepts JPEG/PNG photos up to 20 MiB. Photos already at or below 5 MiB pass through unchanged. Larger photos are oriented and encoded as high-quality JPEG, trying a long edge of 3600, 3200, 2800, then 2400 pixels with quality 92–86; transparency is composited on white. Processing refuses images above 40 megapixels or those that cannot fit the existing 5 MiB server/OCR limit without going below these safeguards. PDFs remain limited to 5 MiB and are never recompressed. The optimised photo is the uploaded/stored copy; the device original is not uploaded.

The full 276-test Flutter suite and production web build passed. Live bundle SHA-256 `B974558835C1E6172C947FDEE69D55136A82BCEEBBFA5D6573251C9A644404CB` matches the build; Worker version `bfcfbeb5-9c5c-423c-9c5b-c1bbe039bb34`. `/app/` and API health returned HTTP 200. Real-device OCR legibility on a photographed page still needs acceptance testing.

## Feedback fixes FD-1 through FD-5 — 2026-09-19

The production app now presents Inbox messages as a familiar email list with sender, date, subject, preview, unread state and compact attachment/link indicators. Feedback creation and follow-up replies use a human acknowledgement instead of a bare ticket result. The login form has consistent field/action spacing. The Home composer now includes a document-category control: a user can select or create the destination for the next attachment, while leaving it unset retains the existing AI category-suggestion flow.

Flutter analysis completed with no errors or warnings (18 pre-existing info lints), and all 277 tests passed. The production build and canonical website routes passed. Live bundle SHA-256 `D8822657AF7E4704BEB183BBE7E77039AC01655D77AF173E9B3592A2A48AC28A` matches the tested build; Worker version `108d5dde-2c18-41a4-8d0f-f8fe2fa35a02`. Public `/`, `/app/`, `/faq`, `/privacy`, `/terms`, and API health returned HTTP 200. Rollback is Worker version `bfcfbeb5-9c5c-423c-9c5b-c1bbe039bb34`.

The separately published Sites source version 23 is retained for source continuity. Its Sites URL remains access-controlled and is not the public production domain. Feedback tickets remain governed by the manual owner-review policy; this release record does not bypass the deliberately absent deployment-evidence service that would mark database tickets `Released`.

## FD-7 secure offline travel pack — 2026-09-19

The production web source now includes the native-mobile FD-7 implementation: explicit per-document offline retention inside Library trips, AES-256-GCM encrypted device storage, account-scoped manifests, expiry/removal controls, and a device-authenticated cold-start vault that re-locks when the app is backgrounded. Web remains deliberately informational because browser storage cannot provide the promised native security and durability boundary.

All 283 Flutter tests passed, including signed-out vault entry, successful and failed device authentication, document-name confidentiality before unlock, and lifecycle re-locking. Analysis reported no errors or warnings. The live bundle SHA-256 is `054839FC649D87FE438EF8B7A21B0F2B80078A5D4FBF0F89CEDF310CCA5BF424`; Worker version `42d691cb-e306-4c00-a49f-05165135d24f` serves it. Public `/`, `/app/`, `/faq`, `/privacy`, `/terms`, and API health returned HTTP 200, and the production bundle matched the tested build. Worker version `108d5dde-2c18-41a4-8d0f-f8fe2fa35a02` remains the rollback reference.

Physical Android/iOS airplane-mode acceptance remains open: this Windows host has no Android SDK or connected device, and iOS signing/testing requires macOS/Xcode. FD-7 therefore remains in progress rather than being represented as fully mobile-accepted.

## Feedback recommendations FD-8 through FD-10 — 2026-09-19

The production app now makes **Email forwarding and allowed senders** a prominent Settings card and uses the same plain-language title on its management screen. The Home composer exposes a labelled **Category** control instead of an unexplained folder icon, and authorised category creators always see **+ New category** with a separate shared-category confirmation form. Reminder creation increments a shared refresh revision, so an already-visible Reminders destination reloads after a successful chat-created reminder. The page also displays its last refresh time and labels due dates as **Today** or **Tomorrow** where applicable.

Flutter analysis completed with no errors or warnings (17 informational lints), the focused Settings/Reminders/Home regression suite passed, and all 284 Flutter tests passed. The website build, lint and production dependency audit passed with zero production dependency vulnerabilities. Sites source version 25 and the canonical Worker version `4c9f5a0b-48b3-41ae-baec-394dd1c4b01b` were published. The live bundle SHA-256 `2D9A4D28E7B743EB5CD48171E3006A66D69ABC88E960D82CF6E40EE8B4D9950A` matches the tested build; `/`, `/app/`, `/faq`, `/privacy`, `/terms`, and API health returned HTTP 200. Worker `42d691cb-e306-4c00-a49f-05165135d24f` remains the rollback reference.

The public sign-in page passed a visible browser smoke check. An authenticated owner smoke test of the three internal screens remains user-facing acceptance because no credentials were entered or retrieved during deployment. The feedback database cards are not marked `Released`: that state remains intentionally unavailable without the separately designed deployment-evidence service.

## Public website alignment — 2026-09-20

The public website was aligned with the production product decisions and recent app releases. All sign-in and registration calls to action now use the canonical `/app/` route. The homepage explains that original documents remain in the family's connected Google Drive while the service stores controlled metadata and derived information. It also describes Rentals as a Library collection organised by property and financial year, rather than a separate product. Privacy and FAQ wording now accurately distinguishes family-visible confirmed Library records from supported private items and Saved Links, and discloses the encrypted Google refresh credential used for Drive access.

The production website build passed all 16 rendered-page tests. Worker version `8b1a7299-27f8-429a-861a-1ae7345fdb68` is active, with `c4d27e9e-13d4-4d27-9c01-d208eeee28b6` retained as the immediate rollback reference. Public `/`, `/app/`, `/privacy`, `/terms`, `/faq`, and the production API health endpoint returned HTTP 200. The live Flutter bundle SHA-256 remains `FB161E5B01AC9D2BF6BA8F811907E3977733F1DD89867BA96AAE7FA7C4F47D2B`, confirming that this website-only release did not alter the tested application bundle.

## PB-07 feedback response lifecycle — 2026-09-20

The production app now closes the feedback loop without exposing one reporter's
cards to another. Owners review the backlog through the local read-only Codex
reviewer, record an explicit reporter-facing decision, and must supply deployment
evidence before marking an item Released. Reporters see unread updates, status
history and release evidence in My feedback. Feedback never authorizes code or
deployment, and the automatic runner remains disabled.

Migration 075 preserved 11 existing tickets. Gateway image
`kia/familydocuments-inbound-gateway:0.6.2-feedback` (digest prefix
`e6e32626b334`) passed its security and hardened-runtime gates. All 287 Flutter
tests passed, and a rollback-only production transaction proved owner response,
reporter visibility and mark-read behavior. Worker version
`082c5391-0b4a-4cbe-9459-f38146cb3973` serves bundle SHA-256
`65755AFFA04522C295129EA08BC1E8EA172BB31A6077FF8405B0A98344A46314`; the
live hash matched, and `/`, `/app/`, `/privacy`, `/terms`, `/faq` and API health
returned HTTP 200. Worker `8b1a7299-27f8-429a-861a-1ae7345fdb68` and gateway
image `0.6.1-notifications` remain the immediate rollback references.
