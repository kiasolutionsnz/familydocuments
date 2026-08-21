# Frozen disposable topology

STATUS: provider images blocked; no start authorized.

## Components

- `fp003r2-db`: exact-digest PostgreSQL on internal `fp003r2-private`; no host port.
- `fp003r2-auth`: exact-digest GoTrue on the private network, loopback mapped only; currently rejected by image policy.
- Host boundary: `src/app-boundary.js`, version-bound `src/gotrue-passkey-adapter.js`, `src/online-authority.js` and static browser page/JS. It binds HTTPS only to `127.0.0.1:43117` in tests.
- Tests: provider-claim/unit suites and actual HTTP integration in `test/*.test.js`; deterministic fake provider is explicitly not GoTrue evidence.

The adapter is frozen to the documented stable GoTrue v2.194.0 passkey options/verify contract. It validates the injected signature-verifier result, issuer, audience, expiry, subject, string `aal2` and `session_id`. It does not invent nonce, credential or provider-session JWT claims. Credential `rawId` remains a candidate until confirmed through the provider passkey list/API. The application action/target step-up challenge remains separate from GoTrue's WebAuthn challenge.

## Lifecycle

Automated local verification: `npm test` from the spike directory. It generates an ephemeral one-hour self-signed PFX in the OS temp directory, starts a real HTTPS loopback listener, performs the contract test with certificate verification disabled only in the Node fixture client, stops the listener and removes the PFX directory. It must leave no listener on 43117.

The executable test origin, site URL, redirect allow-list and WebAuthn RP origin are consistently `https://localhost:43117`; RP ID is `localhost`. The generated test certificate is not installed/trusted. Before actual Chrome attendance a separately approved procedure must trust an ephemeral localhost certificate, verify Chrome behavior, then remove trust and key material. Requirements must not be weakened to HTTP.

## Evidence and cleanup

Capture secret-free status codes, security headers, maximum revocation latency and provider identifiers hashed/redacted according to the evidence plan. Never capture tokens, cookies, biometric/private-key material or environment secrets.

Before cleanup inspect exact names, then remove only `fp003r2-auth`, `fp003r2-db`, `fp003r2-private` and `fp003r2-db-data`. Stop the host process, remove the exact temporary TLS directory and verify port 43117 has no listener. Production Supabase and shared networks are out of scope.

Provider/container execution remains prohibited until an exact stable compatible pair passes pull, provenance, licence, SBOM, vulnerability, KEV and independent review gates.
