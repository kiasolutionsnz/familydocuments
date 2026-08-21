# Browser test contract

Supported initial browser: current stable Chrome on Windows, checked at execution time.

Required endpoint: `https://localhost:43117` with a locally trusted ephemeral certificate. Expected page has one “Start passkey test” button and `role=status`; no application content. CSP permits only same-origin external script/connect, denies framing, base and other resources.

Acceptance:

1. no certificate warning or mixed content;
2. start response exposes no nonce, verifier or CSRF value in JSON;
3. browser accepts `__Host-fp003r2_csrf` and later `__Host-fp003r2_session` only with Secure, HttpOnly, Path=/, no Domain, SameSite=Strict and Max-Age=300;
4. CSRF cookie is expired with Max-Age=0 after success;
5. callback wrong state/provider error fails generically and creates no session;
6. successful provider identity binds subject, AAL, credential and provider-session lifecycle;
7. protected request succeeds before revoke and returns 401 within the measured bound after revoke;
8. browser storage contains no token, nonce, verifier, document data or provider credential.

Automated Node HTTPS tests verify transport, markup, headers, cookie strings and the v2.194.0 options/verify fixture, but deliberately bypass trust for the ephemeral self-signed certificate. Actual Chrome trust/cookie/WebAuthn verification remains blocked until certificate-trust and image gates pass.
