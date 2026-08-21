# FP-004 disposable isolation preflight

This is a synthetic, non-production security feasibility harness. It does not
implement Family Passport features and must not be pointed at shared Supabase or
Bodycorp resources.

## Run

From the workspace root:

```powershell
& .\family-passport\spikes\fp004-isolation\run.ps1
```

The runner creates only exact names prefixed `fp004_`, uses the already-local
immutable `kia-postgres` image, publishes no ports, and removes its disposable
container/network/volume after collecting evidence. Job scratch is generated
under the spike's `.work` directory, is excluded by `backup-allowlist.txt`, and
is forcibly removed after each test.

## Pass boundary

Database controls pass only when every catalog, grant, RLS, signed-context,
pool-clearing, and synthetic reciprocal-schema assertion passes. Runtime parser
containment passes only with `network=none`, read-only root, all Linux
capabilities dropped, no secrets, no database environment, and exact temporary
mount cleanup.

Exact-host broker egress is deliberately not simulated. The runner records
`UNSUPPORTED` unless an independently enforced and inspected egress gateway is
provided. Under FP-004 this makes shared-platform reuse fail closed and triggers
the dedicated API/database boundary fallback.

