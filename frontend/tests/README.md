# Frontend verification

Run from the active site directory, `familydocuments/frontend/frontend`:

```sh
npm ci
npm run test:all
```

`test:all` runs lint, the production build, rendered/model tests and the synthetic Chromium UI suite. `npm run test:browser` runs only the UI suite. Node 22.13+ and an installed Chromium browser are required. On Windows, the suite detects standard Chrome or Edge installations. Elsewhere, set `FD_BROWSER_EXECUTABLE` to the browser executable; the suite also checks `/usr/bin/chromium` and `/usr/bin/google-chrome`.

The browser uses a new, temporary profile and loopback-only test origin. The real application scripts and styles are loaded from `public/`; auth, data, Drive and OCR clients are replaced at the network boundary with synthetic service doubles. All requests outside the test origin are blocked and fail the suite. No personal browser profile, login, real account, email invitation, Google account or real document is used.

The UI suite covers document preview/download, missing/denied/unavailable sources, keyboard activation, loading/deduplication, focus restoration, late requests after navigation, route-message isolation, reminder filters/family responses, connection states/disconnect confirmation, OCR confirmation/rejection/retry and 360px, 390px and 1280px layouts.

Phase B adds seven pure extraction tests for synthetic insurance, passport, receipt and warranty content, ambiguous/invalid dates, conflicts and inert source instructions. Ten additional UI tests cover editable OCR suggestions, separate Create/Join onboarding, generated-alias client contracts, five primary destinations, legacy routes, focused Settings, role visibility, MFA/destructive safeguards, preserved disclosures, and 200% text sizing. The historical `ux-phase-a.browser.test.mjs` filename now contains both phases (25 browser tests total).

To capture optional synthetic layout screenshots, set `FD_CAPTURE_UI=1` and run the browser suite. Screenshots are written as `fd-phase-b-ask-<width>.png` and `fd-phase-b-settings-<width>.png` in the directory specified by `TEMP`; set `TEMP` to an existing scratch directory if your environment does not provide it. These are test artifacts, not production screenshots.

These are browser integration tests, **not** proof of real Google OAuth/Drive behaviour or OCR model accuracy. The separate backend `npm run test:isolated` harness verifies authentication, RPC permissions, database lifecycle and available local service integrations with synthetic accounts. No tests deploy the app.
