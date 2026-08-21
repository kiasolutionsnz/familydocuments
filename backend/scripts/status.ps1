$ErrorActionPreference = 'Stop'
$docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
& $docker ps --filter name=family-passport-supabase --format '{{.Names}}|{{.Status}}|{{.Ports}}|{{.Networks}}'
if ($LASTEXITCODE -ne 0) { throw 'Family Passport Supabase status failed.' }
