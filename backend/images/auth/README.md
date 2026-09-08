# Hardened Supabase Auth

This image preserves the official Supabase Auth `v2.195.0` application source at commit
`0522e7bcf7135a476d258b1603134b97846179fc` while rebuilding it with Go `1.25.13` and
patched `golang.org/x` modules. The runtime is `scratch`, runs as UID/GID `65532`, and
contains only the Auth binary, migrations, CA certificates and timezone data.

The Dockerfile resolves the explicitly pinned patched `golang.org/x` modules from the
clean source checkout and verifies the resulting module graph. The untracked
`upstream-v2.195.0` directory is only a local build context.

Candidate tag: `kia/familydocuments-supabase-auth:v2.195.0-kia.3`.

Promotion requires exact-digest scanning, isolated compatibility testing, application
acceptance, rollback evidence and an update to the platform records.
