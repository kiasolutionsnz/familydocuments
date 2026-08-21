# FP-003 auth gateway contract

An isolated, dependency-free contract for Family Passport authentication and authorisation boundaries.

It covers verified email/password adapter behavior, Google OIDC state/nonce/PKCE and claim checks, opaque secure sessions, AAL2-gated invitations, email-bound single-use invites, and default-deny family/resource grants.

It does **not** provide a live identity provider, password hashing database, Google credentials, SMTP, browser UI, persistence, deployment, or production security evidence. TOTP cryptography and the 72-hour recovery state machine remain in the separately reviewed `fp003-totp` spike. A selected runtime must pass the complete D-025 AB-01–AB-16 matrix before product implementation is unblocked.

`src/http-boundary.js` adds a dependency-free executable request boundary with exact routes/origin, strict JSON shapes and size, generic failures, OIDC binding cookie, session-cookie extraction, CSRF checks and an injected rate-limiter contract. It remains a synthetic handler—not a listening production server.

Run: `node --test`
