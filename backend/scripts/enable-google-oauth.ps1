$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$envFile=Join-Path $root '.env.local'
$docker='C:\Program Files\Docker\Docker\resources\bin\docker.exe'
if(-not (Test-Path -LiteralPath $envFile)){throw '.env.local is required'}
$values=@{};Get-Content -LiteralPath $envFile | ForEach-Object {if($_ -match '^([A-Z0-9_]+)=(.*)$'){$values[$matches[1]]=$matches[2].Trim()}}
foreach($key in @('GOOGLE_OAUTH_CLIENT_ID','GOOGLE_OAUTH_CLIENT_SECRET')){if([string]::IsNullOrWhiteSpace($values[$key]) -or $values[$key] -eq 'not-configured'){throw "$key is not configured"}}
if($values['GOOGLE_OAUTH_ENABLED'] -ne 'true'){throw 'Set GOOGLE_OAUTH_ENABLED=true in .env.local after registering the callback'}
& $docker compose --env-file $envFile -f (Join-Path $root 'docker-compose.yml') config -q
if($LASTEXITCODE -ne 0){throw 'Compose validation failed'}
& $docker compose --env-file $envFile -f (Join-Path $root 'docker-compose.yml') up -d --no-deps auth
if($LASTEXITCODE -ne 0){throw 'Auth recreation failed'}
for($i=0;$i -lt 20;$i++){$status=& $docker inspect --format '{{.State.Health.Status}}' family-passport-supabase-auth-1 2>$null;if($status -eq 'healthy'){break};Start-Sleep -Seconds 2}
if($status -ne 'healthy'){throw 'Auth did not become healthy'}
$settings=Invoke-RestMethod -Uri 'http://127.0.0.1:55321/settings'
if(-not $settings.external.google){throw 'Google provider did not become available'}
Write-Host 'Family Passport Google sign-in is enabled and healthy.'
