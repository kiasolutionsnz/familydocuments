$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
& $docker compose --project-directory $root --env-file (Join-Path $root '.env.local') down
if ($LASTEXITCODE -ne 0) { throw 'Family Passport Supabase stop failed.' }
