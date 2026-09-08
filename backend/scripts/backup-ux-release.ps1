[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$backendRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspaceRoot=(Resolve-Path (Join-Path $backendRoot '../..')).Path
$backupConfigRoot=Join-Path $workspaceRoot 'platform/backups'
$releaseId='fd-ux-'+(Get-Date -Format 'yyyyMMdd-HHmmss')
$releaseDir=Join-Path $backendRoot "backups/$releaseId"
$database='family-passport-supabase-db-1'
$resticImage='restic/restic:0.18.0@sha256:4cf4a61ef9786f4de53e9de8c8f5c040f33830eb0a10bf3d614410ee2fcb6120'
$restoreContainer="$releaseId-restore"
$dumpInside="/tmp/$releaseId.dump"
function Invoke-DockerChecked([string[]]$DockerArgs){
  # PostgreSQL notices use stderr even on success. Check the native exit code,
  # rather than letting Windows PowerShell promote a notice to a fatal error.
  $previousPreference=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    $result=& docker @DockerArgs 2>&1
    $dockerExit=$LASTEXITCODE
  }finally{$ErrorActionPreference=$previousPreference}
  if($dockerExit -ne 0){throw "Docker operation failed during $script:releaseStep ($($DockerArgs[0])); output withheld to protect backup data."}
  return ($result -join "`n").Trim()
}
$settings=@{}
Get-Content -LiteralPath (Join-Path $backupConfigRoot '.env') | Where-Object {$_ -match '^[A-Za-z_][A-Za-z0-9_]*='} | ForEach-Object {$key,$value=$_ -split '=',2;$settings[$key]=$value}
$repoPath=[IO.Path]::GetFullPath($settings.RESTIC_REPOSITORY_PATH)
$passwordFile=[IO.Path]::GetFullPath((Join-Path $backupConfigRoot $settings.RESTIC_PASSWORD_FILE))
foreach($path in @($repoPath,$passwordFile)){if(-not(Test-Path -LiteralPath $path)){throw 'Configured backup repository or password file missing.'}}
$health=Invoke-DockerChecked @('inspect','--format','{{.State.Health.Status}}',$database)
if($health -ne 'healthy'){throw 'Production database is not healthy.'}
$image=Invoke-DockerChecked @('inspect','--format','{{.Image}}',$database)
$null=Invoke-DockerChecked @('image','inspect',$resticImage)
$null=New-Item -ItemType Directory -Path $releaseDir
# A database-native dump is the backup. No live volume copying or broad pruning.
$null=Invoke-DockerChecked @('exec',$database,'pg_dump','-U','postgres','-d','postgres','-Fc','-f',$dumpInside)
$dumpPath=Join-Path $releaseDir 'database.dump'
$null=Invoke-DockerChecked @('cp',"${database}:$dumpInside",$dumpPath)
$null=Invoke-DockerChecked @('exec',$database,'pg_restore','--list',$dumpInside)
$hash=(Get-FileHash -LiteralPath $dumpPath -Algorithm SHA256).Hash
$resticArgs=@('run','--rm','--pull=never','--network','none','--security-opt','no-new-privileges:true','-v',"${releaseDir}:/dumps:ro",'-v',"${repoPath}:/repository",'-v',"${passwordFile}:/run/secrets/restic-password:ro",'-e','RESTIC_REPOSITORY=/repository','-e','RESTIC_PASSWORD_FILE=/run/secrets/restic-password',$resticImage)
$backupResult=Invoke-DockerChecked ($resticArgs+@('backup','/dumps','--tag',$releaseId,'--json'))
$summary=$backupResult -split "`n" | ForEach-Object {try{$_|ConvertFrom-Json}catch{}} | Where-Object {$_.message_type -eq 'summary'} | Select-Object -Last 1
if(-not $summary.snapshot_id){throw 'Encrypted backup did not return a snapshot.'}
$null=Invoke-DockerChecked ($resticArgs+@('check'))
$countSql="select json_build_object('documents',(select count(*) from fp.documents),'members',(select count(*) from fp.members),'manual_sources',(select count(*) from fp.manual_document_sources),'drive_links',(select count(*) from fp.document_external_sources),'invalid_constraints',(select count(*) from pg_constraint where connamespace='fp'::regnamespace and not convalidated));"
$started=$false
try{
  $script:releaseStep='isolated restore container'
  $randomPassword=[Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N')
  $null=Invoke-DockerChecked @('run','-d','--pull=never','--name',$restoreContainer,'--label',"app.familydocuments.release-restore=$releaseId",'--network','none','--security-opt','no-new-privileges:true','--tmpfs','/var/lib/postgresql/data:rw,size=1g','-e',"POSTGRES_PASSWORD=$randomPassword",'-e','POSTGRES_HOST=/var/run/postgresql','-e','PGPORT=5432','-e','POSTGRES_DB=postgres',$image)
  $started=$true
  for($attempt=0;$attempt -lt 90;$attempt++){
    $ready=& docker inspect --format '{{.State.Health.Status}}' $restoreContainer 2>$null
    if($LASTEXITCODE -eq 0 -and $ready -eq 'healthy'){break}
    Start-Sleep -Milliseconds 500
  }
  $script:releaseStep='isolated restore database'
  $null=Invoke-DockerChecked @('exec',$restoreContainer,'createdb','-U','postgres','fd_restore')
  $script:releaseStep='isolated crypto dependency'
  $null=Invoke-DockerChecked @('exec',$restoreContainer,'psql','-U','postgres','-d','fd_restore','-v','ON_ERROR_STOP=1','-c','CREATE SCHEMA IF NOT EXISTS extensions; CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions; CREATE SCHEMA IF NOT EXISTS fp;')
  $null=Invoke-DockerChecked @('cp',$dumpPath,"${restoreContainer}:/tmp/database.dump")
  $script:releaseStep='application backup restore'
  $null=Invoke-DockerChecked @('exec',$restoreContainer,'pg_restore','-U','supabase_admin','-d','fd_restore','--schema=fp','--exit-on-error','/tmp/database.dump')
  $before=Invoke-DockerChecked @('exec',$restoreContainer,'psql','-U','postgres','-d','fd_restore','-Atc',$countSql)
  $migration=Join-Path $backendRoot 'migrations/039_ux_phase_a_original_sources.sql'
  $null=Invoke-DockerChecked @('cp',$migration,"${restoreContainer}:/tmp/migration039.sql")
  $script:releaseStep='migration rehearsal'
  $null=Invoke-DockerChecked @('exec',$restoreContainer,'psql','-U','supabase_admin','-d','fd_restore','-v','ON_ERROR_STOP=1','-f','/tmp/migration039.sql')
  $after=Invoke-DockerChecked @('exec',$restoreContainer,'psql','-U','postgres','-d','fd_restore','-Atc',$countSql)
  if($before -ne $after){throw 'Restored application record counts or constraints changed unexpectedly.'}
  $verified=$after|ConvertFrom-Json
  if($verified.invalid_constraints -ne 0){throw 'Restored application has invalid constraints.'}
  $report=[pscustomobject]@{status='BACKUP_RESTORE_AND_MIGRATION_REHEARSAL_PASS';release=$releaseId;directory=$releaseDir;dump_sha256=$hash;encrypted_snapshot=$summary.snapshot_id;application_counts=$verified;production_migrated=$false}|ConvertTo-Json -Depth 4
  [IO.File]::WriteAllText((Join-Path $releaseDir 'verification.json'),$report)
  $report
}finally{
  if($started){
    $containerInfo=Invoke-DockerChecked @('inspect',$restoreContainer) | ConvertFrom-Json
    $owner=$containerInfo[0].Config.Labels.'app.familydocuments.release-restore'
    if($owner -eq $releaseId){$null=Invoke-DockerChecked @('rm','-f','-v',$restoreContainer)}
  }
}
