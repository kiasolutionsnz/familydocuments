[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$ExistingSitePath,
  [Parameter(Mandatory=$true)][string]$FlutterBuildPath,
  [Parameter(Mandatory=$true)][string]$ReleaseDirectory
)
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath $ExistingSitePath).Path
$build=(Resolve-Path -LiteralPath $FlutterBuildPath).Path
$releaseRoot=(Resolve-Path -LiteralPath $ReleaseDirectory).Path
$backendRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$allowedRoot=[IO.Path]::GetFullPath((Join-Path $backendRoot 'backups'))
if(-not $releaseRoot.StartsWith($allowedRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Release directory must be inside the ignored backend backups folder.'}
$hosting=Join-Path $source '.openai/hosting.json'
$site=Get-Content -LiteralPath $hosting -Raw|ConvertFrom-Json
if($site.project_id -ne 'appgprj_6a85158e62b08191ba1ddb54f77614f8'){throw 'Unexpected public Site identity.'}
foreach($relative in @('package.json','app/page.tsx','app/privacy/page.tsx','app/terms/page.tsx','app/faq/page.tsx')){
  if(-not(Test-Path -LiteralPath (Join-Path $source $relative))){throw "Current public page missing: $relative"}
}
$html=Get-Content -LiteralPath (Join-Path $build 'index.html') -Raw
if(-not $html.Contains('<base href="/prototype/">')){throw 'Flutter build is not targeted at /prototype/.'}
$target=Join-Path $releaseRoot 'pb08-public-site-candidate'
if(Test-Path -LiteralPath $target){throw 'Candidate target already exists; keep it for inspection or choose a fresh release directory.'}
$null=New-Item -ItemType Directory -Path $target
$excludedPrototype=Join-Path $source 'public/prototype'
$excludedDirs=@('node_modules','.next','dist','.wrangler','.sites-runtime',$excludedPrototype)
$excludedFiles=@('.env','.env.local','.dev.vars','google-drive-config.local.js')
& robocopy $source $target /E /R:1 /W:1 /XD $excludedDirs /XF $excludedFiles | Out-Null
if($LASTEXITCODE -ge 8){throw 'Public Site source copy failed.'}
$appTarget=Join-Path $target 'public/prototype'
$null=New-Item -ItemType Directory -Path $appTarget -Force
Copy-Item -Path (Join-Path $build '*') -Destination $appTarget -Recurse -Force
foreach($relative in @('index.html','main.dart.js','flutter_bootstrap.js')){
  if(-not(Test-Path -LiteralPath (Join-Path $appTarget $relative))){throw "Flutter asset missing: $relative"}
}
$report=[ordered]@{
  status='LOCAL_SITE_CANDIDATE_PREPARED'
  site_project_id=$site.project_id
  target=$target
  app_path='/prototype/'
  flutter_bundle_sha256=(Get-FileHash -LiteralPath (Join-Path $appTarget 'main.dart.js') -Algorithm SHA256).Hash
  public_pages_preserved=@('/','/privacy','/terms','/faq')
  site_published=$false
}
[IO.File]::WriteAllText((Join-Path $releaseRoot 'pb08-public-site-candidate.json'),($report|ConvertTo-Json -Depth 3))
Write-Output ($report|ConvertTo-Json -Depth 3)
