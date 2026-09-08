$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$migration=Get-Content -Raw -LiteralPath (Join-Path $root 'migrations\023_saved_links_private_first.sql')
$tests=Get-Content -Raw -LiteralPath (Join-Path $root 'tests\saved-links-private-first.sql')
$sql="begin;`n$migration`n$tests`nrollback;"
$sql | & 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' exec -i family-passport-supabase-db-1 psql -v ON_ERROR_STOP=1 -U supabase_admin -d postgres
if($LASTEXITCODE -ne 0){throw 'Saved Links rollback-only security test failed'}
Write-Host 'Saved Links private-first security test passed and rolled back.'
