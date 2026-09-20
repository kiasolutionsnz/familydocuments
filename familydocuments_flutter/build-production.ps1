[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$DriveClientConfigPath
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path $PSScriptRoot).Path
$config=(Resolve-Path -LiteralPath $DriveClientConfigPath).Path
$entry=Get-Content -LiteralPath $config | Where-Object {$_ -match '^GOOGLE_DRIVE_CLIENT_ID='} | Select-Object -First 1
if(-not $entry){throw 'Google Drive public client ID is missing.'}
$clientId=($entry -split '=',2)[1].Trim()
if($clientId -notmatch '^[A-Za-z0-9._-]{20,200}$'){throw 'Invalid Google Drive public client ID.'}
$flutter='C:/src/flutter/bin/flutter.bat'
if(-not(Test-Path -LiteralPath $flutter)){throw 'Flutter toolchain is unavailable.'}
Push-Location $root
try {
  & $flutter build web --release --base-href=/app/ --dart-define=FAMILYDOCUMENTS_API_BASE_URL=https://api-familydocuments.servicehub.co.nz --dart-define=GOOGLE_DRIVE_CLIENT_ID=$clientId --pwa-strategy=none --no-wasm-dry-run
  if($LASTEXITCODE -ne 0){throw 'Flutter release build failed.'}
  $bundle=Join-Path $root 'build/web/main.dart.js'
  $contents=[IO.File]::ReadAllText($bundle)
  $index=[IO.File]::ReadAllText((Join-Path $root 'build/web/index.html'))
  if(-not $index.Contains('<base href="/app/">') -or
    -not $contents.Contains('https://api-familydocuments.servicehub.co.nz') -or
    $contents.Contains('familydocuments-phase2f-staging.inderchauhan.chatgpt.site') -or
    -not $contents.Contains($clientId)) {throw 'Release build target verification failed.'}
  $shaProvider=[Security.Cryptography.SHA256]::Create()
  try{$clientFingerprint=([BitConverter]::ToString($shaProvider.ComputeHash([Text.Encoding]::UTF8.GetBytes($clientId)))).Replace('-','')}
  finally{$shaProvider.Dispose()}
  $repo=(Resolve-Path (Join-Path $root '..')).Path
  $revision=(& git -c "safe.directory=$repo" -C $repo rev-parse HEAD).Trim()
  if($LASTEXITCODE -ne 0 -or $revision -notmatch '^[a-f0-9]{40}$'){throw 'Unable to resolve source revision.'}
  $manifest=[ordered]@{
    status='LOCAL_BUILD_VERIFIED'
    built_at=(Get-Date).ToUniversalTime().ToString('o')
    api_base_url='https://api-familydocuments.servicehub.co.nz'
    base_href='/app/'
    bundle_sha256=(Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
    bundle_bytes=(Get-Item -LiteralPath $bundle).Length
    drive_client_id_sha256=$clientFingerprint
    git_commit=$revision
    production_published=$false
  }
  $report=Join-Path $root 'build/production-build-evidence.json'
  [IO.File]::WriteAllText($report,($manifest|ConvertTo-Json -Depth 3))
  Write-Output ($manifest|ConvertTo-Json -Depth 3)
}finally{Pop-Location}
