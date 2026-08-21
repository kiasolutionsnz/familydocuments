# FP-004R disposable runtime proof

STATUS: FAIL-CLOSED PREFLIGHT

This directory contains the synthetic FP-004R runtime preflight. It does not
deploy Family Passport, touch Supabase/Bodycorp, publish ports, use real data,
or pull images.

The revision-3 proof requires real, separately isolated runtime identities for
the typed HTTPS gateway, fixed-schema launcher, restricted Docker control
proxy, fixed-profile parser, and the broker/controller/sweeper application
runtime. The launcher request schema, complete signed immutable profile format,
mTLS identities/network and signing-key custody contract are frozen and hash-
bound here, but their concrete digests, keys and runtime remain unselected. A
generic forward proxy, direct Engine socket access from the launcher, or an
unreviewed image is not an acceptable substitute.

Run from the workspace root:

```powershell
& .\family-passport\spikes\fp004r-runtime\run-preflight.ps1
```

The script inventories exact names, frozen dynamic prefixes and both the
product and run labels; checks every native Docker command exit; records the
local image set; binds image presence to promotion-manifest evidence; and exits
non-zero when any prerequisite is unavailable. It creates no Docker resources.
Promotion evidence is content-hashed and must independently approve the exact
digest and scope. Negative tests prove missing fields and mismatched hashes,
digests, profiles, identities and launcher bindings are rejected.
Inline producer-authored approval is never authority: approval must be a
separate reviewer-owned, hashed and Ed25519-signed record with exact component,
tag, digest and configuration bindings.
The verifier performs real Ed25519 verification over a deterministic canonical
payload. Its trusted-key registry must be provisioned and hash-pinned by the
independent reviewer outside this producer evidence directory. That registry is
currently absent, so every candidate remains fail-closed.
