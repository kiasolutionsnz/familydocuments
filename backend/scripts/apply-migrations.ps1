$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$migrations = Get-ChildItem -LiteralPath (Join-Path $root 'migrations') -Filter '*.sql' | Sort-Object Name
foreach ($migration in $migrations) {
  Write-Host "Applying $($migration.Name)"
  Get-Content -Raw -LiteralPath $migration.FullName | & $docker exec -i family-passport-supabase-db-1 psql -v ON_ERROR_STOP=1 -U postgres -d postgres
  if ($LASTEXITCODE -ne 0) { throw "Family Passport migration failed: $($migration.Name)" }
}
