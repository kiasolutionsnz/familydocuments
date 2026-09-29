# Windows Google Drive browser handoff — 2026-09-30

Status: deployed to production.

## Scope

Windows does not have a native Google Sign-In implementation in the app's
supported Flutter stack. Drive management therefore begins in the browser,
where Google sign-in and its MFA controls are available. The desktop app does
not request a redundant local MFA challenge before opening that browser flow.

The browser URL is `https://familydocuments.app/app/?setup=drive`. After a
member signs in, the app opens the Drive settings page. On returning to the
Windows app, its Drive status refreshes automatically. The connection remains
Family-wide and uses the existing server-held encrypted Drive credential; this
release neither changes Drive scopes nor exposes a new API or data store.

## Validation

- Flutter analysis passed for the app shell and Drive screen.
- All 12 focused Drive widget tests passed, including the Windows browser-first
  journey.
- The production Flutter build used `/app/`, the existing production API URL,
  and the existing public Google Drive OAuth client.
- Cloudflare Worker version `0c1c09ae-01df-4e94-9c86-d3c41bb0ec74` was
  published as a frontend-only release. No Docker service, database, Auth
  configuration, or Drive permission changed.
- `https://familydocuments.app/app/?setup=drive` and the production API health
  endpoint returned HTTP 200. The live `main.dart.js` SHA-256 matched the
  verified candidate:
  `AEF52597AFB54147B08D4924165CFBFEC49BFAEB950AA776776D3F8F6ABE1287`.

Rollback: publish the preceding Cloudflare Worker version
`4db0222c-fa15-4645-a2c9-49ce022e896e`.
