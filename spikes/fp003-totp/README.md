# FP-003 D-025 TOTP feasibility harness

This disposable Node.js harness consumes the frozen D-025 semantics through manifest SHA-256 `7BC475F8A55891B65FBB9A7FFAEAFEE1DA22A3598F3889FA1E8B44661DEAE97F`. It exercises deterministic application-boundary fixtures for AAL1, SHA-256 TOTP, AAL2, action-bound step-up, session epoch revocation, recovery codes, the exact 259,200-second recovery clock, cancellation, rollback and audit redaction.

It is deliberately **not** an identity-provider emulator and is not provider proof. No image, external account, SMTP message, secret, production resource or real identity is used. Provider-native hashing, external SMTP acceptance, refresh-token races, durable distributed limiting, browser PKCE/cookies and load/revocation latency remain `UNSUPPORTED` until executed on one exact policy-approved runtime.

Run with `npm test` (no install is required).
