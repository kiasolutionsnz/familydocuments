# Family Passport isolated UI prototype

This is a frontend-only, non-production prototype approved by decision D-031. It demonstrates the calm responsive shell and the Home, Records, Add, Review, Search and contextual Help experiences using synthetic New Zealand household data.

## Run

Open `index.html` directly, or serve this directory with any local static server. The prototype has no build step and makes no network requests.

## Review states

Use **View states** in the top prototype banner to switch between populated, loading, empty, error, restricted, offline, conflict and stale examples. Use browser responsive mode to review desktop, compact and 320px layouts.

## Safety boundary

- No authentication or authorization implementation.
- No database, provider OAuth, Google Drive, OCR, upload, persistence or telemetry.
- No external scripts, fonts or assets.
- All names, files, addresses, policies and dates are synthetic.
- `PrototypeAdapter` in `model.js` is an explicit replaceable, in-memory mock contract used by every household read, search and submit path. It never persists information.
- This work does not complete FP-005, the MVP, or any experience implementation matrix row.

## Static checks

Run `node test.mjs`. The checks use only Node built-ins and verify the no-network boundary, required screens/states, accessibility hooks and responsive CSS markers.
