# Phase 1B deployment

Phase 1B reuses PostgreSQL as the durable queue, the existing authenticated gateway, PaddleOCR, the local Ollama classifier, and the existing Windows worker pattern. It adds no external service.

## Order

1. Back up and apply `migrations/040_phase_1b_reminders_async_ocr.sql`.
2. Deploy the gateway with both the existing synchronous `/documents/analyse` route and the new `/document-analysis/jobs` routes.
3. Register `scripts/register-document-analysis-task.ps1` (or start `npm run document-analysis:watch`) under the existing restricted worker account. Registration is intentionally not performed by this change. The worker uses `FP_API_URL`, `FP_OCR_URL`, `FP_OLLAMA_URL`, `FP_OLLAMA_MODEL`, and `GOTRUE_JWT_SECRET`; the secret remains in the existing environment/`.env.local`, never in Git.
4. Deploy the Flutter client.
5. Verify queue age, retry/dead-letter counts, gateway errors, and a synthetic OCR job before enabling wider use.

The application time-zone convention remains `Pacific/Auckland`. The synchronous endpoint is retained for the static client and may only be removed in a separately approved release.

## Rollback

Roll back the Flutter client and worker first, then the gateway. Leaving migration 040 applied is backward compatible. A database rollback should only occur after confirming there are no standalone reminders or analysis jobs to preserve: drop the Phase 1B functions, policies, job table/indexes and reminder idempotency column/index, restore the original reminder policy, then make `reminders.document_id` required only after removing or linking every standalone row. Never drop the job table while work or results remain.

This phase prepares migration and operations files only. It does not apply or deploy them.
