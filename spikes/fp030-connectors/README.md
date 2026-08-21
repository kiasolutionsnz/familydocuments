# FP-030 connector contract spike

Status: isolated synthetic feasibility code; not production implementation.

This spike defines provider-neutral, fail-closed contracts for Google Drive and Microsoft OneDrive connections:

- OAuth authorization-code transaction binding with PKCE S256, state, an immutable exact redirect allow-list, provider, session, inclusive expiry and single use;
- separate injected trusted ID-token verifier for issuer, audience, subject, account and nonce claims after callback consumption; callers cannot assert a `signatureVerified` boolean;
- least-privilege provider manifests that reject broad whole-drive scopes;
- server-issued picker sessions bound to exact origin, message source and random channel nonce, followed by opaque short-lived, single-use selection grants bound to authenticated owner, connector, provider subject/account, exact file ID and broker-observed immutable live version;
- duplicate-safe connector creation and idempotent/concurrency-safe local-disable-before-provider-revoke disconnect behavior that never changes originals.

It deliberately has no HTTP server, real OAuth client ID, client secret, access/refresh token, token encryption implementation, provider SDK, network call, database or real file. OneDrive has no executable scope set and is disabled for live authorization because Microsoft documents limited support for selected-file Graph permissions; broad `Files.Read.All` is not substituted.

Sources checked 2026-08-19:

- https://developers.google.com/workspace/drive/api/guides/api-specific-auth
- https://developers.google.com/workspace/drive/api/guides/picker
- https://learn.microsoft.com/en-us/onedrive/developer/controls/file-pickers/
- https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/permissions_reference

Run `npm test` in this directory. Passing tests prove only these pure contracts. Live OAuth, token custody, callback transport, broker/gateway behavior, revocation timing and provider compatibility remain blocked by FP-003V, FP-004V and independent review.
