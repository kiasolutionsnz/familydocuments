# Family Documents

Family Documents is organised as a single repository for the web application,
self-hosted backend, product documentation, prototypes, and bounded technical
spikes.

## Repository layout

- `frontend/` — Vinext/Vite application intended for Cloudflare Workers.
- `backend/` — dedicated, self-hosted Supabase development stack.
- `docs/` — product, architecture, research, and decision records.
- `prototype/` — earlier standalone browser prototype.
- `spikes/` — isolated technical validation work.

## Local development

Run frontend commands from `frontend/`:

```powershell
cd frontend
npm install
npm run dev
```

Run backend commands from `backend/` and follow `backend/README.md`. The backend
is currently loopback-only and is not a public production API.

## Cloudflare Git deployment

Connect this repository to Cloudflare Workers Builds and set the root directory
to `frontend`. Use `npm run build` as the build command. Production variables
and secrets belong in Cloudflare configuration, never in tracked `.env` files.
