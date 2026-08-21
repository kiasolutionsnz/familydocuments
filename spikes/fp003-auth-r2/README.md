# FP-003 authentication feasibility revision 2

This disposable reference harness repairs the review findings with server-issued 128-bit challenges, atomic single consumption, recovery-gated factor enrolment, and an application-side online authority/protocol-negative client. Recovery completion revokes all existing passkeys as well as sessions, refresh families and recovery codes.

It is not general application authentication code and is not evidence that an identity provider meets the contract. The local HMAC marker is illustrative and is not a WebAuthn ceremony.

Run `npm test` from this directory.

The suite starts an actual HTTPS loopback boundary on `127.0.0.1:43117` using an ephemeral test PFX, exercises a version-bound GoTrue v2.194.0 passkey options/verify fixture plus `/api/protected`, validates documented string `aal` and `session_id` claims, freezes `Secure` `__Host-` cookies and proves lifecycle revocation. The fixture is not GoTrue/WebAuthn runtime evidence because no eligible stable Auth/PostgreSQL image pair is available. Actual Chrome certificate trust and passkey ceremony remain later gates.
