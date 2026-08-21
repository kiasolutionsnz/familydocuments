# Family Passport local backend

Dedicated loopback-only Supabase development stack for synthetic Family Passport testing.

It must never reuse Bodycorp containers, schemas, databases, networks, volumes, secrets or project identifiers. Real family data is prohibited until the production security gates pass.

Temporary risk boundary: the currently available official Supabase development images contain known Critical/High vulnerability findings and are approved only for closed, loopback-only synthetic development. They must not join `proxy`, bind LAN/public interfaces or be promoted to production.

The minimal stack disables Studio/Postgres Meta, Realtime, Storage, Edge Runtime and Analytics. Local email is inspected through Mailpit/Inbucket only.

`family_passport_db` is an internal network with no published database port. `family_passport_app` is a normal bridge because Docker Desktop requires it for loopback port forwarding and future provider egress; Auth and Mailpit publish only to `127.0.0.1`.

## Local commands

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
Mailpit: `http://127.0.0.1:55324`

The household API exposes only the `fp` schema through authenticated RPCs. Tables use forced row-level security and are not directly granted to browser roles. Invitations are recorded locally for seven days; local invitation email delivery is intentionally not enabled yet.

The local OCR path accepts authenticated PDF/JPEG/PNG requests from the exact preview origin, validates size and SHA-256, processes in ephemeral `/tmp`, and deletes source bytes before replying. OCR text is non-authoritative and is persisted only through the explicit confirmation RPC. This remains fictional/synthetic testing only.

`stop` preserves the database volume. Do not use `supabase start`; the CLI-generated stack publishes broader services and ports and is intentionally not the runtime for this project.
