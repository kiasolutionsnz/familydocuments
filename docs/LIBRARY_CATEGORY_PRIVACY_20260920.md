# Library category privacy release — 2026-09-20

Status: Deployed to production.

This release repairs Library category creation and adds an explicit choice
between **Private to me** and **Share with Family**. Private categories are
visible only to their member owner in the Library. Shared category creation is
restricted to Family owners/admins and requires an AAL2 authenticator check.
The UI now presents the six-digit authenticator code as six responsive boxes.
New empty categories remain visible and open immediately after creation.

The privacy label is deliberately app-scoped: the connected Google Drive owner
can still access originals stored in that Drive. Existing categories were
preserved as shared.

## Verification and deployment evidence

- Isolated PostgreSQL migration replay and `phase-2b-library.sql`: PASS,
  including creator visibility and family-admin non-disclosure for a private
  category.
- Focused Flutter Library and Drive tests: 28 passed.
- Targeted Dart analysis: no issue in the changed code; one pre-existing style
  information item remains in `offline_travel_store_io.dart`.
- Pre-migration production category count: 346. Post-migration: 346 shared,
  zero invalid constraints.
- Snapshot: `backend/backups/category-privacy-20260920-1958/database.dump`,
  SHA-256 `11CE7C02E178E21FDC4FEFC74536F54997F5CDC3AE0732F5FE119DA96CA1B729`.
- Migration: `076_library_category_visibility.sql`.
- Production Flutter bundle SHA-256:
  `79CE131E3360B134C82A10E5755513A617985C4F6D831D42C42A0EBCD3CB3D52`.
- Cloudflare Worker version: `0bc084f6-c7cc-4b16-920a-a07e4d5e8aab`.
- Live `/`, `/app/`, `/terms`, `/privacy`, and API health returned HTTP 200;
  the live app bundle matched the tested build hash.

The release candidate's generic ESLint command also inspected generated
Flutter/PDF runtime JavaScript and reported third-party/generated-code lint
errors. Authored Flutter code was instead validated with Dart analysis, widget
tests, the production Flutter compiler, and the deployed bundle hash.
