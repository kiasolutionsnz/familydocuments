$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
if (-not (Test-Path -LiteralPath (Join-Path $root '.env.local'))) {
  throw 'Missing .env.local. Run scripts/new-local-secrets.ps1 once.'
}
& $docker compose --project-directory $root --env-file (Join-Path $root '.env.local') up -d
if ($LASTEXITCODE -ne 0) { throw 'Family Passport Supabase startup failed.' }
