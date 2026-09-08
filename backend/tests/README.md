# Safe backend tests

Run `npm run test:isolated` from `backend`. Individual `test:auth`, `test:mfa`,
`test:foundation`, `test:google-auth`, `test:google-drive`, `test:operations`,
`test:inbox-ingestion`, `test:attachment-scanner`, `test:search` and `test:e2e`
commands use the same disposable harness. A focused SQL run is:

```powershell
node scripts/test-isolated.mjs ux-phase-a-original-sources.sql
```

The harness creates a unique `fd-test-<random>` Docker project equivalent with
temporary PostgreSQL storage, synthetic secrets, independent Auth, Mailpit,
PostgREST and the current cached gateway. It does not load `.env.local`, mount
production data/signature volumes, join production networks, or send external
email. All published ports bind `127.0.0.1` in the 57000–63999 range. The database
network is internal and has no published ports. The separate test application
bridge is needed for Docker's loopback mappings and official ClamAV signature
downloads; it is not attached to Traefik or a public network.

All migrations are replayed from empty. API tests register only synthetic
`@family-passport.test` accounts and confirm mail captured by the isolated Mailpit.
MFA-sensitive actions use real Auth TOTP verification, not forged AAL2 claims.
Email intake uses the current HMAC gateway and sender allow-list. Source lifecycle
tests run the real cached PaddleOCR image against an in-memory synthetic insurance
PDF, explicitly confirm a draft, race duplicate confirmations, open the original
byte-for-byte, and deny another family access. Search tests target `/search/ask`
on the gateway, not the obsolete standalone service port.

Docker must be available and the exact release tags listed in
`scripts/test-isolated.mjs` must already be cached. The harness uses `--pull=never`.
OCR may take a minute to start. ClamAV uses fresh definitions from its official
mirror in temporary container storage and fails closed if updates are unavailable;
it never falls back to the production scanner. An unavailable OCR/scanner is a
failed suite, not a skipped success. Other suites continue and results are printed.

Resources are removed in `finally`, only after validating their unique ownership
label. A hard process/host termination can prevent that cleanup; use a read-only
`docker ps -a --filter label=app.familydocuments.test-run` inventory, inspect the
exact label, and remove only a confirmed abandoned test run. Never use a global
Docker prune or the production Compose stop/down command for test cleanup.

Offline Node tests:

```powershell
node --test tests/relative-date.test.mjs tests/notification-template.test.mjs tests/ux-source-retention.test.mjs
```

Go source tests can use the cached compiler without network or writable source:

```powershell
docker run --rm --pull=never --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp:rw,exec,size=256m --mount "type=bind,source=$PWD/inbound-gateway,target=/src,readonly" -e GOCACHE=/tmp/go-cache -e GOPATH=/tmp/go -e GOTOOLCHAIN=local -w /src golang:1.26.6-alpine3.23 go test ./...
```

These checks are local acceptance only. They do not publish the frontend, migrate
the live database, change production services or verify real Google account access.
