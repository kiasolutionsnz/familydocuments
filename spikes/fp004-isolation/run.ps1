$ErrorActionPreference = 'Stop'
$spikeRoot = $PSScriptRoot
$workspace = (Resolve-Path (Join-Path $spikeRoot '..\..\..')).Path
$evidence = Join-Path $workspace 'software-factory\runs\family-passport-2026-08-17\delivery\fp004-isolation'
$work = Join-Path $spikeRoot '.work'
$docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$container = 'fp004_postgres'
$network = 'fp004_db_internal'
$volume = 'fp004_pgdata'
$image = 'kia-postgres:15.18-gosu1.19-go1.26.4@sha256:975758eb2d9c1c0ac2afd84511686aa37ab71667d110aebee89c26dd972f39a4'
$dbPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
$executorPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
$jobPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
$bodycorpPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))

New-Item -ItemType Directory -Force -Path $evidence,$work | Out-Null
$log = Join-Path $evidence 'run.log'
Set-Content -LiteralPath $log -Value "FP-004 started $(Get-Date -Format o)"

function Invoke-Docker([string[]]$Arguments) {
  & $docker @Arguments 2>&1 | Tee-Object -FilePath $log -Append
  if ($LASTEXITCODE -ne 0) { throw "docker command failed: $($Arguments -join ' ')" }
}

try {
  $existing = & $docker ps -a --format '{{.Names}}' | Where-Object { $_ -in @($container) }
  if ($existing) { throw "Refusing to overwrite existing exact resource: $existing" }
  $existingNetwork = & $docker network ls --format '{{.Name}}' | Where-Object { $_ -eq $network }
  if ($existingNetwork) { throw "Refusing to overwrite existing exact network: $network" }
  $existingVolume = & $docker volume ls --format '{{.Name}}' | Where-Object { $_ -eq $volume }
  if ($existingVolume) { throw "Refusing to overwrite existing exact volume: $volume" }

  Invoke-Docker @('network','create','--internal',$network)
  Invoke-Docker @('volume','create',$volume)
  Invoke-Docker @('run','-d','--name',$container,'--network',$network,'--network-alias','fp004-db',
    '--mount',"type=volume,src=$volume,dst=/var/lib/postgresql/data",
    '-e',"POSTGRES_PASSWORD=$dbPassword",'-e','POSTGRES_DB=fp004',$image)

  $ready = $false
  foreach ($i in 1..30) {
    & $docker exec $container pg_isready -U postgres -d fp004 *> $null
    if ($LASTEXITCODE -eq 0) { $ready=$true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $ready) { throw 'Disposable PostgreSQL did not become ready' }

  Get-Content -Raw (Join-Path $spikeRoot 'sql\001_isolation.sql') |
    & $docker exec -i $container psql -v ON_ERROR_STOP=1 -v "executor_password=$executorPassword" -v "job_password=$jobPassword" -v "bodycorp_password=$bodycorpPassword" -U postgres -d fp004 2>&1 |
    Tee-Object -FilePath $log -Append
  if ($LASTEXITCODE -ne 0) { throw 'Database setup failed' }
  Get-Content -Raw (Join-Path $spikeRoot 'sql\002_tests.sql') |
    & $docker exec -i $container psql -v ON_ERROR_STOP=1 -U postgres -d fp004 2>&1 |
    Tee-Object -FilePath $log -Append
  if ($LASTEXITCODE -ne 0) { throw 'Database assertions failed' }

  $job = Join-Path $work 'job-0001'
  $inbox = Join-Path $job 'inbox'; $output = Join-Path $job 'output'; $scratch = Join-Path $job 'scratch'
  New-Item -ItemType Directory -Force -Path $inbox,$output,$scratch | Out-Null
  Set-Content -LiteralPath (Join-Path $inbox 'synthetic.txt') -Value 'synthetic non-sensitive fixture'
  $parserEvidence = Join-Path $evidence 'parser-containment.txt'
  & $docker run --rm --network none --read-only --user 65532:65532 --cap-drop ALL --security-opt no-new-privileges:true `
    --tmpfs /tmp:rw,noexec,nosuid,size=16m `
    --mount "type=bind,src=$inbox,dst=/input,readonly" `
    --mount "type=bind,src=$output,dst=/output" `
    --mount "type=bind,src=$scratch,dst=/scratch" `
    --entrypoint /bin/sh $image -c 'set -eu; test "$(id -u)" != 0; test -r /input/synthetic.txt; test ! -w /input/synthetic.txt; test -w /output; test -w /scratch; test ! -w /; test -z "${DATABASE_URL:-}"; test -z "${PGHOST:-}"; test -z "${GOOGLE_TOKEN:-}"; test -z "${AWS_ACCESS_KEY_ID:-}"; ! getent hosts fp004-db; ! getent hosts metadata.google.internal; printf PARSER_CONTAINMENT_PASS' 2>&1 |
    Tee-Object -FilePath $parserEvidence
  if ($LASTEXITCODE -ne 0) { throw 'Parser containment failed' }

  $inspect = & $docker inspect $container | ConvertFrom-Json
  @(
    "database_network_internal=$((& $docker network inspect $network --format '{{.Internal}}').Trim())"
    "database_published_ports=$($inspect[0].NetworkSettings.Ports | ConvertTo-Json -Compress)"
    'controller_credentials=NOT_IMPLEMENTED_IN_SPIKE'
    'broker_exact_host_egress=UNSUPPORTED_NO_ENFORCING_GATEWAY'
    'existing_bodycorp_reciprocal_catalog=NOT_TESTED_PRODUCTION_OUT_OF_SCOPE'
    'synthetic_bodycorp_reciprocal_catalog=PASS'
  ) | Set-Content -LiteralPath (Join-Path $evidence 'boundary-results.txt')

  $allow = Get-Content -Raw (Join-Path $spikeRoot 'backup-allowlist.txt')
  if ($allow -match '(?m)^\s*(inbox|output|scratch|transient-capture|\.work)\s*$') { throw 'Transient path present in backup allowlist' }
  Remove-Item -LiteralPath $job -Recurse -Force
  if (Test-Path -LiteralPath $job) { throw 'Forced cleanup failed' }
  @('backup_allowlist_transient_exclusion=PASS','forced_job_cleanup=PASS') | Set-Content -LiteralPath (Join-Path $evidence 'cleanup-results.txt')
  Add-Content -LiteralPath $log -Value "Executable controls complete $(Get-Date -Format o)"
}
finally {
  $named = & $docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $container }
  if ($named) { & $docker rm -f $container | Out-Null }
  $namedNetwork = & $docker network ls --format '{{.Name}}' | Where-Object { $_ -eq $network }
  if ($namedNetwork) { & $docker network rm $network | Out-Null }
  $namedVolume = & $docker volume ls --format '{{.Name}}' | Where-Object { $_ -eq $volume }
  if ($namedVolume) { & $docker volume rm $volume | Out-Null }
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
  Add-Content -LiteralPath $log -Value "Exact temporary resources cleaned $(Get-Date -Format o)"
}
