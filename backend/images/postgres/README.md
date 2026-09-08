# Hardened Supabase PostgreSQL

This image preserves the exact official Supabase PostgreSQL `17.6.1.159` image at
digest `sha256:86a2e078779e5bdccda1f6f6c5063aa9779a322d1fface5fb408d051909b230f`.
It replaces only `/usr/local/bin/gosu`, whose Go `1.26.1` runtime accounts for all
fixable Critical/High findings in that base image.

The replacement is official gosu `1.19` source at commit
`6456aaa0f3c854d199d0f037f068eb97515b7513`, rebuilt with pinned Go `1.26.6`.
PostgreSQL, Supabase extensions, entrypoint scripts, configuration, users and data
directory behavior remain inherited unchanged from the exact compatible base.

The otherwise-unused curl command and libcurl runtime are removed. They have no APK
reverse dependencies and are not referenced by the entrypoint, database initialization
scripts or configuration. This removes six unfixed curl findings and reduces the
database container's outbound-capable tooling.

The final stage copies the merged runtime filesystem into a single clean layer so
scanners do not attribute the overwritten vulnerable binary from base-image history.
The exact base runtime environment, entrypoint, command, port, health check and stop
signal are reproduced explicitly.

Candidate tag: `kia/familydocuments-supabase-postgres:17.6.1.159-kia.3`.

Promotion requires exact-digest scanning, independent binary/advisory validation,
an isolated restore and application regression, a fresh live backup, targeted
deployment, persistence validation and recorded rollback evidence.
