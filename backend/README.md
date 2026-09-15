# Family Passport local backend

Dedicated loopback-only Supabase development stack for synthetic Family Passport testing.

It must never reuse Bodycorp containers, schemas, databases, networks, volumes, secrets or project identifiers. Real family data is prohibited until the production security gates pass.

Temporary risk boundary: the currently available official Supabase development images contain known Critical/High vulnerability findings and are approved only for closed, loopback-only synthetic development. They must not join `proxy`, bind LAN/public interfaces or be promoted to production.

## Gateway build and test memory

The Google Drive/inbound gateway is Go source, but the supported runtime and
validation environment is its pinned Docker build image (`golang:1.26.6-alpine`)
in `inbound-gateway/Dockerfile`. A local Windows Go installation is optional and
is not required. Validate gateway changes through the isolated Docker build and
test path so the compiler/runtime match the candidate that can reach staging.

The minimal stack disables Studio/Postgres Meta, Realtime, Storage, Edge Runtime and Analytics. Local email is inspected through Mailpit/Inbucket only.

`family_passport_db` is an internal network with no published database port. `family_passport_app` is a normal bridge because Docker Desktop requires it for loopback port forwarding and future provider egress; Auth and Mailpit publish only to `127.0.0.1`.

## Local commands

For current automated validation, use `npm run test:isolated` and
[the safe test guide](tests/README.md). The historical `start`, `migrate` and `stop`
commands below target the named application stack; they are not test setup and
must not be run without explicit authority for that deployment.

From this directory:

```powershell
npm run start
npm run migrate
npm run status
npm run test:auth
npm run test:foundation
npm run test:e2e
npm run stop
```

Auth health: `http://127.0.0.1:55321/health`  
Household API: `http://127.0.0.1:55322`  
PaddleOCR API: `http://127.0.0.1:55323/health`  
Production-style Auth email uses the SMTP provider configured in `.env.local`.

Inbound attachment scanning and classification are separate supervised workers. Register them with `scripts/register-attachment-scanner-task.ps1` and `scripts/register-classifier-task.ps1`; the registration scripts use S4U startup tasks and therefore require administrator approval. `scripts/check-inbound-email-health.ps1` monitors worker liveness even when queues are empty, pre-classification attachments, missing body-only classification jobs and classification jobs. It restarts only the affected worker, permits at most three restart attempts per worker per hour, verifies task and queue recovery, and reports privacy-safe recovery or failure through Telegram. Unattended startup must still be proved with a controlled reboot before it is treated as production-ready.

Reminder emails are queued with migration 038 for 08:00 `Pacific/Auckland` on the actual due date. The reminder creator is the only recipient by default; active household members are included only when whole-family email was explicitly enabled. The same five-minute health check detects a stopped or duplicated notification worker, a due-day reminder missing its notification record after 08:10, and delivery still active more than ten minutes after availability. Recovery removes only exact Family Documents notification-worker processes, starts one supervised worker, verifies one process and a clear due-day queue, and uses the same three-attempts-per-hour safety limit.

**Historical walkthrough — not the automated-test setup.** The following Mailpit
steps, `family-passport.local` aliases and invitation-delivery notes describe the
earlier development architecture. The named Compose stack and `553xx` ports may
now serve the live application. Do not run this override, test accounts, workers,
fixtures or cleanup commands against that stack for test validation. Current
tests must use `npm run test:isolated`; see [safe backend tests](tests/README.md)
for disposable services, synthetic credentials and the current HMAC email flow.
The historical command below changes services and requires separate, explicit
authority for the exact intended deployment target.

Mailpit was available for synthetic local tests using the development override:

```powershell
docker compose --env-file .env.local -f docker-compose.yml -f docker-compose.development.yml --profile development up -d
```

Mailpit UI: `http://127.0.0.1:55324`
Mailpit SMTP: `127.0.0.1:55325`

Each bootstrapped household receives a random `@family-passport.local` inbox visible only to its owner or family admins. Copy, rotate, disable and re-enable controls are available in Household settings. This local address is not an authentication factor and does not receive internet mail.

Send a fictional message to a generated address with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/send-synthetic-inbox-email.ps1 -To 'family-<generated-id>@family-passport.local'
```

To test a quarantined PDF attachment, add `-AttachmentPath tests/fixtures/synthetic-bill.pdf`. Then run the bounded one-shot ingestion worker:

```powershell
npm run inbox:ingest
```

For continuous local synthetic testing, run `npm run inbox:watch`; it polls Mailpit every five seconds. This is a development process, not a production mail service.

The worker reads Mailpit, accepts only the exact active household alias, verifies a SHA-256 hash at the database boundary, and stores the immutable RFC822 source plus safe metadata. It is idempotent by Mailpit message ID. Attachments remain embedded in the source email and are marked `quarantined_unscanned`; they are not extracted, previewed, classified or OCR-processed.

The isolated Family Passport ClamAV service listens only on `127.0.0.1:55326`. Run `npm run attachments:scan` once or `npm run attachments:watch` for continuous local scanning. The scanner re-downloads the exact Mailpit MIME part, verifies its API-reported size and SHA-256, checks it with fresh ClamAV signatures, then validates a minimal PDF signature/EOF boundary. Only a clean, structurally valid PDF is persisted separately; malware, malformed and unsupported attachments retain no extracted bytes.

The household API exposes only the `fp` schema through authenticated RPCs. Tables use forced row-level security and are not directly granted to browser roles. Invitations are recorded locally for seven days; local invitation email delivery is intentionally not enabled yet.

The local OCR path accepts authenticated PDF/JPEG/PNG requests from the exact preview origin, validates size and SHA-256, processes in ephemeral `/tmp`, and deletes source bytes before replying. OCR text is non-authoritative and is persisted only through the explicit confirmation RPC. This remains fictional/synthetic testing only.

`stop` preserves the database volume. Do not use `supabase start`; the CLI-generated stack publishes broader services and ports and is intentionally not the runtime for this project.
